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
        case .screen: L.t("Screen recording", "Enregistrement de l'écran", "화면 녹화")
        case .microphone: L.t("Microphone", "Micro", "마이크")
        case .accessibility: L.t("Accessibility", "Accessibilité", "손쉬운 사용")
        }
    }

    var detail: String {
        switch self {
        case .screen: L.t("Required: lets WatchRecorder record what you show.", "Obligatoire : pour enregistrer ce que tu montres.", "필수: 보여 주는 화면을 WatchRecorder가 녹화해요.")
        case .microphone: L.t("So the AI hears what you ask.", "Pour que l'IA entende ce que tu demandes.", "AI가 요청을 들을 수 있게 해요.")
        case .accessibility: L.t("Optional: presses ⌘V for you.", "Facultatif : fait ⌘V à ta place.", "선택: ⌘V를 대신 눌러 줘요.")
        }
    }

    var granted: Bool {
        switch self {
        case .screen: ScreenAccess.granted
        case .microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .accessibility: AXIsProcessTrusted()
        }
    }

    /// Shows the system dialog when macOS still allows it, else opens the right Settings pane.
    @MainActor func request() async {
        switch self {
        case .screen:
            // The first request shows macOS's prompt (with its own "Open System Settings" button)
            // and adds the app to the list; opening Settings at the same time would show both.
            let firstTime = !Settings.screenPromptShown
            Settings.screenPromptShown = true
            if !CGRequestScreenCaptureAccess(), !firstTime, let url = SettingsPane.screenRecording.url { NSWorkspace.shared.open(url) }
        case .microphone:
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .audio)
            } else if let url = SettingsPane.microphone.url {
                NSWorkspace.shared.open(url)
            }
        case .accessibility:
            Delivery.enableAutoPaste()
        }
    }
}

/// Setup order: what works in place first (microphone, shortcut, options), then Screen Recording
/// right before the first recording, since it goes through System Settings and may need a relaunch.
enum OnboardingStep: Int, CaseIterable {
    case welcome, microphone, shortcut, quality, connect, screen, tryIt

    var next: OnboardingStep? { OnboardingStep(rawValue: rawValue + 1) }
    var previous: OnboardingStep? { OnboardingStep(rawValue: rawValue - 1) }

    /// The setup step to show at launch, or nil for the library: where the user left an
    /// unfinished setup (past Screen Recording once it is allowed, as after macOS's
    /// "Quit & Reopen"), else the start when screen recording is not allowed.
    static func atLaunch(resume: Int?, screenAllowed: Bool) -> OnboardingStep? {
        if let resume, let step = OnboardingStep(rawValue: resume) {
            return step == .screen && screenAllowed ? step.next : step
        }
        return screenAllowed ? nil : .welcome
    }
}

/// One AI app as reported by `watch-mcp install --dry-run --json`.
struct AIClientStatus: Decodable, Identifiable {
    let client: String
    let label: String
    /// "absent", "ok", "add" or "update".
    let action: String
    var id: String { client }
}

@MainActor @Observable
final class OnboardingModel {
    var step: OnboardingStep = .welcome
    var granted: [Permission: Bool] = [:]
    var levels: [Double] = Array(repeating: 0, count: 24)
    var heardVoice = false
    var shortcutTested = false
    /// The user clicked to allow Screen Recording during this setup.
    var screenAsked = false
    var shortcut = Settings.hotKey.display
    var quality = Settings.quality
    var clients: [AIClientStatus] = []
    var clientsMessage: String?
    var installing = false
    var sendTo = Settings.sendTo
    var autoPaste = Settings.autoPaste
    /// Set when a recording finishes while the last step is shown.
    var tryResult: String?
    var library = RecordingLibrary()

    func refreshPermissions() {
        for permission in Permission.allCases { granted[permission] = permission.granted }
        autoPaste = Settings.autoPaste
    }

    func isGranted(_ permission: Permission) -> Bool { granted[permission] ?? false }
}

/// Listens to the microphone during the onboarding test and turns it into bar levels.
@MainActor
final class MicMeter {
    private let engine = AVAudioEngine()
    private var running = false

    func start(onLevel: @escaping @MainActor @Sendable (Double) -> Void) {
        guard !running, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0 else { return }
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: MicMeter.tap(onLevel: onLevel))
        do {
            try engine.start()
            running = true
        } catch {
            input.removeTap(onBus: 0)
        }
    }

    func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
    }

    /// Made outside the main actor on purpose: AVAudioEngine calls the tap on its own audio
    /// queue, and a block created inside this @MainActor class traps there (Swift 6 isolation check).
    nonisolated static func tap(onLevel: @escaping @MainActor @Sendable (Double) -> Void) -> AVAudioNodeTapBlock {
        { buffer, _ in
            guard let samples = buffer.floatChannelData?[0] else { return }
            let count = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<count { sum += samples[i] * samples[i] }
            let rms = count > 0 ? (sum / Float(count)).squareRoot() : 0
            let level = min(1, max(0, (20 * log10(max(Double(rms), 1e-6)) + 50) / 50))
            Task { @MainActor in onLevel(level) }
        }
    }
}

/// A step-by-step setup, in the spirit of dictation apps: one thing per screen, each one tested
/// for real (the microphone shows your voice, the shortcut must be pressed, a first recording is
/// made), so the user sees it work instead of trusting a checklist.
@MainActor
final class OnboardingController {
    let model = OnboardingModel()
    private var window: NSWindow?
    private var poll: Timer?
    private let mic = MicMeter()
    private var advance: Task<Void, Never>?
    /// Whether the current step had already worked when the user arrived on it (then it does not
    /// move on by itself, so Back stays usable).
    private var stepWasDone = false
    /// Set by the app: re-registers the global shortcut.
    var changeShortcut: (String) -> Void = { _ in }
    var openDashboard: () -> Void = {}

    var isVisible: Bool { window?.isVisible ?? false }

    init() {
        NotificationCenter.default.addObserver(forName: .watchRecorderLanguageChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let window = self.window else { return }
                window.contentView = NSHostingView(rootView: OnboardingView(controller: self, model: self.model))
            }
        }
    }

    func show(at step: OnboardingStep? = nil) {
        if let step { model.step = step }
        model.refreshPermissions()
        model.library.reload()
        if window == nil { window = makeWindow() }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        poll?.invalidate()
        poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.model.refreshPermissions()
                self?.advanceWhenDone()
            }
        }
        stepChanged()
    }

    func close() {
        poll?.invalidate()
        poll = nil
        mic.stop()
        window?.close()
    }

    func go(to step: OnboardingStep) {
        model.step = step
        stepChanged()
    }

    /// Forward, past Screen Recording when it is already allowed.
    func next() {
        guard var step = model.step.next else { return }
        if step == .screen, model.isGranted(.screen), let after = step.next { step = after }
        go(to: step)
    }

    func requestScreen() {
        model.screenAsked = true
        Task { await Permission.screen.request() }
    }

    func back() {
        if let step = model.step.previous { go(to: step) }
    }

    /// Whether the current step has worked: permission given, voice heard, shortcut pressed.
    private func isDone(_ step: OnboardingStep) -> Bool {
        switch step {
        case .screen: model.isGranted(.screen)
        case .microphone: model.heardVoice
        case .shortcut: model.shortcutTested
        default: false
        }
    }

    /// Moves on by itself a moment after the current step works, so the user only acts where
    /// needed and sees the check mark first.
    private func advanceWhenDone() {
        guard advance == nil, !stepWasDone, isDone(model.step) else { return }
        let from = model.step
        advance = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard let self, !Task.isCancelled, self.model.step == from else { return }
            self.next()
        }
    }

    /// While the shortcut step is shown, pressing the shortcut is a test, not a recording.
    var consumesShortcut: Bool { isVisible && model.step == .shortcut }

    func shortcutPressed() {
        model.shortcutTested = true
        advanceWhenDone()
    }

    func recordingFinished(summary: String) {
        guard isVisible, model.step == .tryIt else { return }
        model.tryResult = summary
        model.library.reload()
    }

    func applyShortcut(_ text: String) {
        changeShortcut(text)
        model.shortcut = Settings.hotKey.display
        model.shortcutTested = false
    }

    /// Relaunches the app and reopens this step (macOS applies screen recording at launch).
    func relaunchAndResume() {
        Settings.onboardingResumeStep = model.step.rawValue
        OnboardingController.relaunch()
    }

    /// Asks watch-mcp which AI apps are here and whether they are connected; with `install`,
    /// connects them first (the user clicked the button).
    func refreshClients(install: Bool) async {
        model.installing = install
        defer { model.installing = false }
        do {
            if install { _ = try await Handoff.watchMcp(["install", "--json"]) }
            let line = try await Handoff.watchMcp(["install", "--dry-run", "--json"])
            model.clients = try JSONDecoder().decode([AIClientStatus].self, from: Data(line.utf8))
            model.clientsMessage = nil
        } catch {
            model.clientsMessage = L.t("Could not run watch-mcp: ", "Impossible de lancer watch-mcp : ", "watch-mcp를 실행할 수 없어요: ") + error.localizedDescription
        }
    }

    /// End of setup: the next launches open on the library.
    func finish() {
        Settings.setupFinished = true
        Settings.onboardingResumeStep = nil
        close()
        openDashboard()
    }

    private func stepChanged() {
        if !Settings.setupFinished { Settings.onboardingResumeStep = model.step.rawValue }
        advance?.cancel()
        advance = nil
        stepWasDone = isDone(model.step)
        mic.stop()
        if model.step == .microphone, model.isGranted(.microphone) { startMic() }
        // Checked on every visit: an AI app may have been set up or installed meanwhile.
        if model.step == .connect { Task { await refreshClients(install: false) } }
        if model.step == .tryIt { model.tryResult = nil }
    }

    func startMic() {
        mic.start { [weak self] level in
            guard let self else { return }
            self.model.levels = Array(self.model.levels.dropFirst()) + [level]
            if level > 0.45 {
                self.model.heardVoice = true
                self.advanceWhenDone()
            }
        }
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 620), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.title = "WatchRecorder"
        window.contentView = NSHostingView(rootView: OnboardingView(controller: self, model: model))
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }

    /// Starts a fresh copy of the app, then quits this one.
    static func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 0.5; /usr/bin/open \"$0\"", Bundle.main.bundleURL.path]
        try? process.run()
        NSApp.terminate(nil)
    }
}
