import AppKit
import Foundation

/// The part of `watch-mcp finalize --json` output the app uses.
struct FinalizeJSON: Decodable {
    let status: String
    let message: String
    let language: String?
    let text: String
}

enum HandoffError: LocalizedError {
    case watchMcpFailed(String)

    var errorDescription: String? {
        switch self {
        case .watchMcpFailed(let detail): "watch-mcp failed: \(detail)"
        }
    }
}

/// Everything around a recording: the .watch bundle on disk, the call to watch-mcp,
/// the state file for the MCP server, and the prompt.
enum Handoff {
    static let appVersion = "0.1.0"

    /// A new, empty "Recording <date>.watch" folder in the recordings folder.
    static func newBundle(at date: Date = Date()) throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let folder = Settings.recordingsFolder.appendingPathComponent("Recording \(formatter.string(from: date)).watch", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// The bundle's video: the manifest's "video" entry when there is one (bundles from other
    /// producers may use another name), else video.mov (what WatchRecorder writes).
    static func videoURL(in bundle: URL) -> URL {
        if let data = try? Data(contentsOf: bundle.appendingPathComponent("manifest.json")),
           let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let name = manifest["video"] as? String,
           !name.isEmpty, !name.hasPrefix("/"), !name.split(separator: "/").contains("..") {
            return bundle.appendingPathComponent(name)
        }
        return bundle.appendingPathComponent("video.mov")
    }

    /// Writes manifest.json and timeline.json (input events only; watch-mcp adds speech and keyframes).
    static func writeBundle(_ bundle: URL, createdAt: Date, duration: Double, events: [[String: Any]]) throws {
        let manifest: [String: Any] = [
            "format": "watch-bundle",
            "version": 1,
            "video": "video.mov",
            "createdAt": iso(createdAt),
            "duration": duration,
            "recorder": ["name": "WatchRecorder", "version": appVersion],
        ]
        let timeline: [String: Any] = ["version": 1, "events": events]
        try json(manifest).write(to: bundle.appendingPathComponent("manifest.json"), options: .atomic)
        try json(timeline).write(to: bundle.appendingPathComponent("timeline.json"), options: .atomic)
    }

    /// Runs `<WatchMcpCommand> finalize <bundle> --json` in a login shell, so the user's PATH (node, npx)
    /// applies. The path is passed as "$1", never spliced into the command string.
    static func finalize(_ bundle: URL, timeout: TimeInterval = 900) async throws -> FinalizeJSON {
        let line = try await runWatchMcp(["finalize", "\"$1\"", "--json"], path: bundle.path, timeout: timeout)
        do {
            return try JSONDecoder().decode(FinalizeJSON.self, from: Data(line.utf8))
        } catch {
            throw HandoffError.watchMcpFailed("unexpected output")
        }
    }

    /// Returns the last stdout line (progress goes to stderr).
    private static func runWatchMcp(_ arguments: [String], path: String, timeout: TimeInterval) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "\(Settings.watchMcpCommand) \(arguments.joined(separator: " "))", "watch-recorder", path]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Date() > deadline {
                process.terminate()
                throw HandoffError.watchMcpFailed("timed out after \(Int(timeout)) s")
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        let out = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let err = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            let lastLine = err.split(whereSeparator: \.isNewline).last.map(String.init) ?? "exit \(process.terminationStatus)"
            throw HandoffError.watchMcpFailed(lastLine)
        }
        return out.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
    }

    /// Writes latest-recording.json for the MCP `latest_recording` tool (atomic replace).
    static func publishLatest(path: URL, startedAt: Date, duration: Double, transcript: String?) throws {
        let folder = Settings.stateFolder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var payload: [String: Any] = [
            "version": 1,
            "path": path.path,
            "startedAt": iso(startedAt),
            "duration": duration,
        ]
        payload["transcript"] = transcript ?? NSNull()
        try json(payload).write(to: folder.appendingPathComponent("latest-recording.json"), options: .atomic)
    }

    /// What the user said, from the finalize result: text, "" for no speech, nil when not transcribed.
    static func spokenText(_ result: FinalizeJSON) -> String? {
        switch result.status {
        case "ok": result.text
        case "no-speech": ""
        default: nil
        }
    }

    /// The text put on the clipboard: paste it into Claude Code / Claude Desktop.
    static func prompt(recording: URL, duration: Double, transcript: String?) -> String {
        let spoken = transcript.map { $0.isEmpty ? "(no speech detected)" : "\"\($0)\"" } ?? "(not transcribed)"
        return """
        Watch my screen recording and do what I ask in it.

        Recording: \(recording.path) (\(clock(duration)))
        What I said: \(spoken)

        Use the watch-mcp tools (latest_recording, or watch_video with the path above) to see what I showed on screen.
        """
    }

    static func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func clock(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func json(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }
}
