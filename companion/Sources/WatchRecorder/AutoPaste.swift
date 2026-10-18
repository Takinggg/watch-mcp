import AppKit
import ApplicationServices
import Carbon

/// After a recording, brings Claude to the front and pastes the prompt (⌘V) into its message
/// box, the way dictation apps paste text. Pasting into another app needs the Accessibility
/// permission; without it the prompt stays on the clipboard.
@MainActor
enum AutoPaste {
    static let claudeBundleID = "com.anthropic.claudefordesktop"

    enum Outcome: Equatable {
        case pasted(into: String)
        case needsAccessibility
        case copiedOnly(reason: String?)
    }

    /// `frontmostAtStop`: the app in front when the recording stopped (for PasteInto = frontmost).
    static func deliver(frontmostAtStop: NSRunningApplication?) async -> Outcome {
        let setting = Settings.pasteInto
        if setting == "off" { return .copiedOnly(reason: nil) }
        let target: NSRunningApplication?
        switch setting {
        case "frontmost": target = frontmostAtStop
        case "claude": target = NSRunningApplication.runningApplications(withBundleIdentifier: claudeBundleID).first
        default: target = NSRunningApplication.runningApplications(withBundleIdentifier: setting).first
        }
        guard let target, let url = target.bundleURL else {
            return .copiedOnly(reason: L.t("Claude is not open", "Claude n'est pas ouvert"))
        }
        guard AXIsProcessTrusted() else {
            // Shows the system dialog (once); the user turns WatchRecorder on in Accessibility.
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            return .needsAccessibility
        }
        // Opening a running app brings it to the front like a Dock click, which macOS allows
        // from a background app (a plain activate() may be ignored).
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        for _ in 0..<30 where NSWorkspace.shared.frontmostApplication?.processIdentifier != target.processIdentifier {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier else {
            return .copiedOnly(reason: L.t("could not bring \(target.localizedName ?? "the app") to the front", "impossible d'afficher \(target.localizedName ?? "l'app")"))
        }
        // Let the app restore focus to its text field before pasting.
        try? await Task.sleep(for: .milliseconds(250))
        pressCommandV()
        return .pasted(into: target.localizedName ?? "Claude")
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
