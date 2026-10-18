import AppKit
import ApplicationServices
import AVFoundation
import SwiftUI

/// The permissions WatchRecorder uses, and their current state.
enum Permission: CaseIterable, Identifiable {
    case screen, microphone, accessibility

    var id: Self { self }

    var title: String {
        switch self {
        case .screen: L.t("Screen recording", "Enregistrement de l'écran")
        case .microphone: L.t("Microphone", "Micro")
        case .accessibility: L.t("Accessibility", "Accessibilité")
        }
    }

    var detail: String {
        switch self {
        case .screen: L.t("Required: lets WatchRecorder record what you show.", "Obligatoire : pour enregistrer ce que tu montres.")
        case .microphone: L.t("So Claude hears what you ask.", "Pour que Claude entende ce que tu demandes.")
        case .accessibility: L.t("Optional: pastes the prompt into Claude for you (⌘V).", "Facultatif : colle le prompt dans Claude à ta place (⌘V).")
        }
    }

    var granted: Bool {
        switch self {
        case .screen: CGPreflightScreenCaptureAccess()
        case .microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .accessibility: AXIsProcessTrusted()
        }
    }

    var settingsURL: URL? {
        let base = "x-apple.systempreferences:com.apple.preference.security?"
        switch self {
        case .screen: return URL(string: base + "Privacy_ScreenCapture")
        case .microphone: return URL(string: base + "Privacy_Microphone")
        case .accessibility: return URL(string: base + "Privacy_Accessibility")
        }
    }

    /// Shows the system dialog when macOS still allows it, else opens the right Settings pane.
    @MainActor func request() async {
        switch self {
        case .screen:
            if !CGRequestScreenCaptureAccess() { open() }
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .notDetermined: _ = await AVCaptureDevice.requestAccess(for: .audio)
            default: open()
            }
        case .accessibility:
            if !AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) { open() }
        }
    }

    private func open() {
        if let settingsURL { NSWorkspace.shared.open(settingsURL) }
    }
}

@MainActor @Observable
final class OnboardingModel {
    var states: [Permission: Bool] = [:]
    var mcpCommand = ""
    var copied = false

    func refresh() {
        for permission in Permission.allCases { states[permission] = permission.granted }
    }
}

/// A small window that walks a new user through the permissions and connecting Claude.
/// Opens at launch whenever screen recording is not allowed (so on first launch), and from the menu.
@MainActor
final class OnboardingController {
    private let model = OnboardingModel()
    private var window: NSWindow?
    private var poll: Timer?

    func show() {
        model.mcpCommand = Self.claudeCommand()
        model.refresh()
        if window == nil {
            let view = OnboardingView(model: model, relaunch: { Self.relaunch() }, close: { [weak self] in self?.close() })
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 470), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "WatchRecorder"
            window.contentView = NSHostingView(rootView: view)
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        // Microphone and Accessibility switch to granted live; screen recording needs a relaunch.
        poll?.invalidate()
        poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.refresh() }
        }
    }

    func close() {
        poll?.invalidate()
        poll = nil
        window?.close()
    }

    /// The command that adds watch-mcp to Claude Code, matching how this app runs watch-mcp.
    static func claudeCommand() -> String {
        "claude mcp add -s user watch -- \(Settings.watchMcpCommand)"
    }

    /// Starts a fresh copy of the app, then quits this one (macOS applies screen recording at launch).
    static func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 0.5; /usr/bin/open \"$0\"", Bundle.main.bundleURL.path]
        try? process.run()
        NSApp.terminate(nil)
    }
}

struct OnboardingView: View {
    let model: OnboardingModel
    let relaunch: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L.t("Welcome to WatchRecorder", "Bienvenue dans WatchRecorder")).font(.title2.bold())
            Text(L.t("Press \(Settings.hotKey.display), show something while you explain it out loud, press \(Settings.hotKey.display) again: Claude watches it and does what you asked.",
                     "Appuie sur \(Settings.hotKey.display), montre ton écran en expliquant à voix haute, rappuie sur \(Settings.hotKey.display) : Claude regarde et fait ce que tu as demandé."))
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(Permission.allCases) { permission in
                PermissionRow(permission: permission, granted: model.states[permission] ?? false)
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text(L.t("Connect Claude Code", "Brancher Claude Code")).font(.headline)
                HStack {
                    Text(model.mcpCommand).font(.system(.caption, design: .monospaced)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Spacer()
                    Button(model.copied ? L.t("Copied", "Copié") : L.t("Copy", "Copier")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.mcpCommand, forType: .string)
                        model.copied = true
                    }
                }
                Text(L.t("Run it once in a terminal. Claude Desktop and Cursor: see the README.", "À lancer une fois dans un terminal. Claude Desktop et Cursor : voir le README."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            HStack {
                if !(model.states[.screen] ?? false) {
                    Text(L.t("Allowed screen recording? Relaunch to apply it.", "Écran autorisé ? Relance pour l'appliquer.")).font(.caption).foregroundStyle(.secondary)
                    Button(L.t("Relaunch", "Relancer"), action: relaunch)
                }
                Spacer()
                Button(L.t("Done", "Terminé"), action: close).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 500, height: 470)
    }
}

private struct PermissionRow: View {
    let permission: Permission
    let granted: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .font(.title2).foregroundStyle(granted ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(permission.title).font(.headline)
                Text(permission.detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                Button(L.t("Allow", "Autoriser")) { Task { await permission.request() } }
            }
        }
    }
}
