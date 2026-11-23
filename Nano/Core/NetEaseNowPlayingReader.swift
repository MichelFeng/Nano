import Darwin
import Foundation

struct NetEaseNowPlayingSnapshot: Sendable {
    let track: MediaNowPlaying
    let artworkIdentifier: String?
}

enum NetEaseNowPlayingReader {
    private struct Payload: Decodable {
        let bundleID: String
        let title: String
        let artist: String?
        let position: Double?
        let duration: Double?
        let rate: Double?
        let sampledAt: Double?
        let artworkIdentifier: String?
    }

    private static let queue = DispatchQueue(label: "com.nanoapp.Nano.netease-now-playing", qos: .utility)

    static func read() async -> NetEaseNowPlayingSnapshot? {
        await withCheckedContinuation { continuation in
            queue.async {
                let track = runScript().flatMap { parse($0) }
                continuation.resume(returning: track)
            }
        }
    }

    static func parse(_ data: Data, at receivedAt: Date = .now) -> NetEaseNowPlayingSnapshot? {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.bundleID == MediaPlayerKind.netease.bundleIdentifier else { return nil }
        let title = payload.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }

        let rate = payload.rate.flatMap { $0 == 0 || (0.0625...16).contains($0) ? $0 : nil }
        let timing: (position: TimeInterval, duration: TimeInterval, date: Date)?
        if let position = payload.position, position.isFinite, position >= 0,
           let duration = payload.duration, duration > 0, duration < Double(Int32.max),
           let sampledAt = payload.sampledAt, sampledAt > 0,
           sampledAt <= receivedAt.timeIntervalSince1970 + 1,
           rate != nil {
            timing = (min(position, duration), duration, Date(timeIntervalSince1970: sampledAt))
        } else {
            timing = nil
        }

        return NetEaseNowPlayingSnapshot(
            track: MediaNowPlaying(
                player: .netease,
                title: title,
                artist: payload.artist?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                isPlaying: (rate ?? 0) > 0,
                position: timing?.position ?? 0,
                duration: timing?.duration ?? 0,
                sampledAt: timing?.date ?? receivedAt,
                playbackRate: timing == nil ? 0 : rate ?? 0
            ),
            artworkIdentifier: payload.artworkIdentifier.flatMap { identifier in
                guard !identifier.isEmpty, identifier.utf8.count <= 256 else { return nil }
                return identifier
            }
        )
    }

    static func artworkData(identifier: String) async -> Data? {
        guard !identifier.isEmpty, identifier.utf8.count <= 256 else { return nil }
        return await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: runArtworkScript(identifier: identifier))
            }
        }
    }

    private static func runScript(arguments: [String] = []) -> Data? {
        let process = Process()
        let stdout = Pipe()
        let exited = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", "-e", script, "--"] + arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            return nil
        }
        try? stdout.fileHandleForWriting.close()
        defer { try? stdout.fileHandleForReading.close() }

        guard exited.wait(timeout: .now() + .seconds(2)) == .success else {
            if process.isRunning { process.terminate() }
            if exited.wait(timeout: .now() + .milliseconds(100)) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        return try? stdout.fileHandleForReading.read(upToCount: 4_096)
    }

    private static func runArtworkScript(identifier: String) -> Data? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nano-netease-artwork-\(UUID().uuidString).data")
        defer { try? FileManager.default.removeItem(at: url) }
        guard let result = runScript(arguments: [identifier, url.path]),
              String(data: result, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == "ok",
              let data = try? Data(contentsOf: url),
              !data.isEmpty, data.count <= 1_048_576
        else { return nil }
        return data
    }

    // Keep the private framework and its callback bridge inside the read-only subprocess.
    private static let script = #"""
        ObjC.import('Foundation');
        ObjC.bindFunction('objc_msgSend', ['void', ['id', 'selector', 'id', 'id']]);

        function run(argv) {
            if (argv.length !== 0 && argv.length !== 2) return 'null';
            const artworkMode = argv.length === 2;
            const bundleID = 'com.netease.163music';
            const media = $.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework');
            if (!media.load) return 'null';
            const origin = $.NSClassFromString('MROrigin');
            const player = $.NSClassFromString('MRPlayer');
            const pathClass = $.NSClassFromString('MRPlayerPath');
            const requestClass = $.NSClassFromString('MRNowPlayingRequest');
            const path = pathClass.alloc.initWithOriginBundleIdentifierPlayer(origin.localOrigin, bundleID, player.defaultPlayer);
            const source = ObjC.unwrap(path.client.bundleIdentifier);
            if (source !== bundleID) return 'null';
            const request = requestClass.alloc.initWithPlayerPath(path);
            const deadline = $.NSDate.dateWithTimeIntervalSinceNow(artworkMode ? 1.5 : 0.7);
            function fetch(selectorName) {
                const selector = $.NSSelectorFromString(selectorName);
                if (!request.respondsToSelector(selector)) return null;
                let result;
                const callback = ObjC.block(['void', ['id', 'id']], (value, error) => {
                    result = value.isNil() || !error.isNil() ? null : value;
                });
                const holder = $.NSPredicate.predicateWithBlock(callback);
                $.objc_msgSend(request, selector, holder.valueForKey('block'), null);
                while (result === undefined && deadline.timeIntervalSinceNow > 0) {
                    $.NSRunLoop.currentRunLoop.runUntilDate($.NSDate.dateWithTimeIntervalSinceNow(0.02));
                }
                return result === undefined ? null : result;
            }
            function artworkIdentifier(info) {
                if (info === null) return null;
                const value = ObjC.unwrap(info.objectForKey('kMRMediaRemoteNowPlayingInfoArtworkIdentifier'));
                return typeof value === 'string' ? value : null;
            }

            if (artworkMode) {
                if (!argv[0] || argv[0].length > 256 || !argv[1]) return 'invalid arguments';
                const infoSelector = 'requestNowPlayingInfoWithCompletion:';
                if (artworkIdentifier(fetch(infoSelector)) !== argv[0]) return 'stale artwork';
                const artwork = fetch('requestNowPlayingItemArtworkWithCompletion:');
                if (artwork === null) return 'missing artwork';
                const data = artwork.imageData;
                if (data.isNil() || data.length < 1 || data.length > 1_048_576) return 'invalid size';
                if (artworkIdentifier(fetch(infoSelector)) !== argv[0]) return 'changed artwork';
                return data.writeToFileAtomically(argv[1], true) ? 'ok' : 'write failed';
            }

            const info = fetch('requestNowPlayingInfoWithCompletion:');
            if (info === null) return 'null';
            const field = (key) => ObjC.unwrap(info.objectForKey('kMRMediaRemoteNowPlayingInfo' + key));
            const number = (value) => typeof value === 'number' && Number.isFinite(value) ? value : null;
            const text = (value) => typeof value === 'string' ? value : null;
            const stamp = info.objectForKey('kMRMediaRemoteNowPlayingInfoTimestamp');
            const result = {
                bundleID: source,
                title: text(field('Title')),
                artist: text(field('Artist')),
                position: number(field('ElapsedTime')),
                duration: number(field('Duration')),
                rate: number(field('PlaybackRate')),
                sampledAt: stamp.isNil() ? null : number(stamp.timeIntervalSince1970),
                artworkIdentifier: artworkIdentifier(info),
            };
            let output = JSON.stringify(result);
            if (output.length >= 1_024) {
                delete result.artworkIdentifier;
                output = JSON.stringify(result);
            }
            return output.length < 1_024 ? output : 'null';
        }
        """#
}
