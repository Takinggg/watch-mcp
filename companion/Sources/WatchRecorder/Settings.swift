import Carbon
import Foundation

/// User settings, stored in the app's defaults domain:
///   defaults write io.github.takinggg.watchrecorder HotKey "ctrl+opt+r"
///   defaults write io.github.takinggg.watchrecorder WatchMcpCommand "node /path/to/watch-mcp/dist/cli.js"
enum Settings {
    /// UserDefaults is thread-safe (documented), but not marked Sendable.
    nonisolated(unsafe) static let defaults = UserDefaults.standard

    /// Command that runs watch-mcp; "transcribe <file> --json" is appended.
    /// Order: WATCH_MCP_COMMAND env, the WatchMcpCommand default, a watch-mcp checkout this app was
    /// built in (companion/build/WatchRecorder.app next to dist/cli.js), then `npx -y watch-mcp`.
    static var watchMcpCommand: String {
        if let env = ProcessInfo.processInfo.environment["WATCH_MCP_COMMAND"], !env.isEmpty { return env }
        let value = defaults.string(forKey: "WatchMcpCommand")?.trimmingCharacters(in: .whitespaces) ?? ""
        if !value.isEmpty { return value }
        let checkout = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let cli = checkout.appendingPathComponent("dist/cli.js")
        if FileManager.default.fileExists(atPath: cli.path) { return "node \(shellQuote(cli.path))" }
        return "npx -y watch-mcp"
    }

    private static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static var recordingsFolder: URL {
        if let path = defaults.string(forKey: "RecordingsFolder"), !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Movies")
        return movies.appendingPathComponent("WatchRecorder", isDirectory: true)
    }

    /// Recordings stop by themselves after this long, so a forgotten one cannot fill the disk.
    static var maxMinutes: Double {
        let value = defaults.double(forKey: "MaxMinutes")
        return value > 0 ? min(value, 120) : 10
    }

    /// Which app gets the prompt after a recording: "auto" (the AI app you were using: Claude,
    /// ChatGPT/Codex, Cursor, VS Code or a terminal), "claude", "codex", "off", or a bundle id.
    static var sendTo: String {
        get {
            let value = defaults.string(forKey: "SendTo")?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            return value.isEmpty ? "auto" : value
        }
        set { defaults.set(newValue, forKey: "SendTo") }
    }

    /// Press ⌘V in that app for you (needs Accessibility). Off by default.
    static var autoPaste: Bool {
        get { defaults.bool(forKey: "AutoPaste") }
        set { defaults.set(newValue, forKey: "AutoPaste") }
    }

    static var appLanguage: AppLanguage {
        get { AppLanguage(rawValue: defaults.string(forKey: "AppLanguage") ?? "") ?? .auto }
        set {
            defaults.set(newValue.rawValue, forKey: "AppLanguage")
            NotificationCenter.default.post(name: .watchRecorderLanguageChanged, object: nil)
        }
    }

    static var quality: Quality {
        get { Quality(rawValue: defaults.string(forKey: "Quality") ?? "") ?? .balanced }
        set { defaults.set(newValue.rawValue, forKey: "Quality") }
    }

    static var recordMicrophone: Bool {
        get { defaults.object(forKey: "RecordMicrophone") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "RecordMicrophone") }
    }

    /// Folder shared with the watch-mcp server (same rule as its stateDir()).
    static var stateFolder: URL {
        if let override = ProcessInfo.processInfo.environment["WATCH_MCP_STATE_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("watch-mcp", isDirectory: true)
    }

    static var hotKey: HotKeySpec {
        HotKeySpec.parse(defaults.string(forKey: "HotKey") ?? "") ?? HotKeySpec.default
    }

    /// Stores a shortcut in the same text form users can write with `defaults` ("ctrl+opt+r").
    static func setHotKey(_ text: String) {
        defaults.set(text, forKey: "HotKey")
    }

    /// Onboarding step to reopen after the app relaunches itself (screen recording needs a relaunch).
    static var onboardingResumeStep: Int? {
        get { defaults.object(forKey: "OnboardingResume") as? Int }
        set { defaults.set(newValue, forKey: "OnboardingResume") }
    }
}

/// A global shortcut such as "opt+shift+r".
struct HotKeySpec: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var display: String

    static let `default` = HotKeySpec(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(optionKey | shiftKey), display: "⌥⇧R")

    private static let keys: [String: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F,
        "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
        "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R,
        "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
        "y": kVK_ANSI_Y, "z": kVK_ANSI_Z, "space": kVK_Space,
        "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
        "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
    ]

    /// Parses "ctrl+opt+cmd+shift+<key>"; needs at least one modifier.
    static func parse(_ text: String) -> HotKeySpec? {
        let parts = text.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let last = parts.last, let key = keys[last], parts.count >= 2 else { return nil }
        var modifiers = 0
        var symbols = ""
        for part in parts.dropLast() {
            switch part {
            case "ctrl", "control": modifiers |= controlKey; symbols += "⌃"
            case "opt", "option", "alt": modifiers |= optionKey; symbols += "⌥"
            case "shift": modifiers |= shiftKey; symbols += "⇧"
            case "cmd", "command": modifiers |= cmdKey; symbols += "⌘"
            default: return nil
            }
        }
        return HotKeySpec(keyCode: UInt32(key), modifiers: UInt32(modifiers), display: symbols + last.uppercased())
    }
}
