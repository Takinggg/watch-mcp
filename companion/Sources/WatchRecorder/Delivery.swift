import AppKit
import ApplicationServices
import Carbon

/// Apps where people talk to an AI: the desktop apps and the editors and terminals that run
/// Claude Code or Codex. The recording is handed to the one you were using.
enum AIApps {
    static let claude = "com.anthropic.claudefordesktop"
    static let codex = "com.openai.codex"
    static let bundleIDs: [String] = [
        claude,
        codex,
        "com.openai.chat",
        "com.todesktop.230313mzl4w4u92", // Cursor
        "com.microsoft.VSCode",
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "com.mitchellh.ghostty",
    ]

    static func isKnown(_ app: NSRunningApplication?) -> Bool {
        guard let id = app?.bundleIdentifier else { return false }
        return bundleIDs.contains(id)
    }
}

/// Remembers which AI app was used last, so a recording made while showing another app
/// still goes back to the conversation you came from.
@MainActor
final class AppTracker {
    private(set) var lastAIApp: NSRunningApplication?
    private var observer: NSObjectProtocol?

    func start() {
        if AIApps.isKnown(NSWorkspace.shared.frontmostApplication) { lastAIApp = NSWorkspace.shared.frontmostApplication }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                if AIApps.isKnown(app) { self?.lastAIApp = app }
            }
        }
    }
}

/// Hands the prompt over after a recording: the prompt goes on the clipboard, the AI app you
/// were using comes back to the front on its current conversation (no permission needed), and,
/// only if you turned on "Paste automatically" and allowed Accessibility, ⌘V is pressed for you.
/// It never shows a permission dialog by itself.
@MainActor
enum Delivery {
    enum Outcome: Equatable {
        case opened(app: String, pasted: Bool)
        case copiedOnly(reason: String?)
    }

    static func deliver(frontmostAtStop: NSRunningApplication?, lastAIApp: NSRunningApplication?) async -> Outcome {
        guard let target = resolveTarget(frontmostAtStop: frontmostAtStop, lastAIApp: lastAIApp) else {
            let off = Settings.sendTo == "off"
            return .copiedOnly(reason: off ? nil : L.t("no Claude or Codex window open", "aucune app Claude ou Codex ouverte", "열려 있는 Claude나 Codex 창이 없어요"))
        }
        let name = target.localizedName ?? "Claude"
        guard let url = target.bundleURL else { return .copiedOnly(reason: nil) }
        // Opening a running app brings it to the front like a Dock click, on the conversation it
        // was showing. macOS allows this from a background app without any permission.
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        guard Settings.autoPaste, AXIsProcessTrusted() else { return .opened(app: name, pasted: false) }
        for _ in 0..<30 where NSWorkspace.shared.frontmostApplication?.processIdentifier != target.processIdentifier {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier else {
            return .opened(app: name, pasted: false)
        }
        // Let the app restore focus to its text field before pasting.
        try? await Task.sleep(for: .milliseconds(250))
        pressCommandV()
        return .opened(app: name, pasted: true)
    }

    /// SendTo = auto: the AI app in front when you stopped, else the one you used last, else any
    /// running one (Claude first). SendTo = claude / codex / a bundle id: that app if it runs.
    static func resolveTarget(frontmostAtStop: NSRunningApplication?, lastAIApp: NSRunningApplication?) -> NSRunningApplication? {
        let running = { (id: String) in NSRunningApplication.runningApplications(withBundleIdentifier: id).first }
        switch Settings.sendTo {
        case "off": return nil
        case "claude": return running(AIApps.claude)
        case "codex": return running(AIApps.codex)
        case "auto":
            if AIApps.isKnown(frontmostAtStop) { return frontmostAtStop }
            if let lastAIApp, !lastAIApp.isTerminated { return lastAIApp }
            return AIApps.bundleIDs.lazy.compactMap(running).first
        case let bundleID: return running(bundleID)
        }
    }

    /// Turning on automatic pasting is the only moment WatchRecorder asks for Accessibility.
    static func enableAutoPaste() {
        Settings.autoPaste = true
        if !AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary),
           let url = SettingsPane.accessibility.url {
            NSWorkspace.shared.open(url)
        }
    }

    /// Posts ⌘V. kVK_ANSI_V is a key position, the same on QWERTY and AZERTY.
    private static func pressCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let key = CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
