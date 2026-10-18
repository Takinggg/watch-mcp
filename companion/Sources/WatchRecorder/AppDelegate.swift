import AppKit
import AVFoundation
import os

/// Unified logging: `log stream --predicate 'subsystem == "io.github.takinggg.watchrecorder"'`
let log = Logger(subsystem: "io.github.takinggg.watchrecorder", category: "app")

/// The menu-bar app: one shortcut starts and stops a recording of the screen under the mouse
/// plus the microphone; on stop it transcribes, tells watch-mcp, and copies a ready prompt.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum Phase { case idle, starting, recording, finishing, transcribing }

    private var statusItem: NSStatusItem?
    private let recorder = Recorder()
    private let eventLog = EventLog()
    private let hud = HUDController()
    private let onboarding = OnboardingController()
    private lazy var dashboard = DashboardController(onboarding: onboarding)
    private let tracker = AppTracker()
    private var bundleURL: URL?
    private var recordingHostStart = 0.0
    private var hotKey: HotKey?
    private var phase: Phase = .idle { didSet { refresh() } }
    private var lastPrompt: String?
    private var micInUse = false
    private var notice: String?
    private var noticeTask: Task<Void, Never>?
    private var ticker: Timer?
    private var autoStop: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        DockIcon.apply()
        NSApp.mainMenu = MainMenu.make(target: self, settings: #selector(openSettings), quit: #selector(quit))
        tracker.start()
        NotificationCenter.default.addObserver(forName: .watchRecorderLanguageChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                NSApp.mainMenu = MainMenu.make(target: self, settings: #selector(self.openSettings), quit: #selector(self.quit))
                self.refresh()
            }
        }
        let spec = Settings.hotKey
        hotKey = HotKey(spec) { [weak self] in self?.toggle() }
        log.info("screen access at launch: preflight \(CGPreflightScreenCaptureAccess(), privacy: .public), window titles \(ScreenAccess.otherAppWindowTitlesVisible(), privacy: .public)")
        log.info("launched; shortcut \(spec.display, privacy: .public) \(self.hotKey == nil ? "NOT registered" : "registered", privacy: .public); watch-mcp command: \(Settings.watchMcpCommand, privacy: .public)")
        hud.model.shortcut = spec.display
        hud.model.onStop = { [weak self] in self?.toggle() }
        hud.model.onOpenSettings = { [weak self] pane in
            self?.hud.hide()
            if let url = pane.url { NSWorkspace.shared.open(url) }
        }
        if hotKey == nil {
            show(L.t("\(spec.display) is used by another app. Pick another shortcut (see README).", "\(spec.display) est déjà pris par une autre app. Choisis un autre raccourci (voir README).", "\(spec.display)는 다른 앱이 쓰고 있어요. 다른 단축키를 골라 주세요(README 참고)."), seconds: 30)
            hud.show(.problem(L.t("Shortcut \(spec.display) is taken by another app", "Raccourci \(spec.display) déjà pris par une autre app", "단축키 \(spec.display)를 다른 앱이 쓰고 있어요"), settings: nil), hideAfter: 8)
        } else if let step = OnboardingStep.atLaunch(resume: Settings.onboardingResumeStep, screenAllowed: ScreenAccess.granted) {
            // An unfinished setup picks up where the user left it; a new user (or a removed
            // permission) starts it. show() saves the step again while setup is unfinished.
            log.info("setup opens at step \(step.rawValue)")
            Settings.onboardingResumeStep = nil
            onboarding.show(at: step)
        } else {
            // Opening the app shows its window: the menu bar icon can be hidden behind the notch.
            dashboard.show()
            hud.show(.done(L.t("WatchRecorder is ready: press \(spec.display) to record", "WatchRecorder est prêt : \(spec.display) pour enregistrer", "WatchRecorder 준비 완료: \(spec.display)로 녹화하세요")), hideAfter: 4)
        }
        onboarding.changeShortcut = { [weak self] text in self?.applyHotKey(text) }
        onboarding.openDashboard = { [weak self] in self?.dashboard.show() }
        dashboard.model.sendToAI = { [weak self] recording in Task { await self?.send(recording) } }
        dashboard.model.startRecording = { [weak self] in self?.toggle() }
        dashboard.model.openSetup = { [weak self] in self?.onboarding.show(at: .welcome) }
        recorder.onUnexpectedStop = { [weak self] error in
            log.error("capture stopped unexpectedly: \(error.localizedDescription, privacy: .public)")
            self?.phase = .idle
            self?.show(L.t("Recording stopped: ", "Enregistrement arrêté : ", "녹화가 멈췄어요: ") + error.localizedDescription)
            self?.hud.show(.problem(L.t("Recording stopped", "Enregistrement arrêté", "녹화가 멈췄어요"), settings: nil), hideAfter: 6)
        }
        refresh()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.logStatusIconPlacement()
        }
    }

    @objc func toggle() {
        if onboarding.consumesShortcut {
            onboarding.shortcutPressed()
            return
        }
        switch phase {
        case .idle: Task { await startRecording() }
        case .recording: Task { await stopRecording() }
        case .starting, .finishing, .transcribing: NSSound.beep()
        }
    }

    private func startRecording() async {
        phase = .starting
        hud.show(.starting)
        micInUse = Settings.recordMicrophone
        if micInUse, !(await AVCaptureDevice.requestAccess(for: .audio)) {
            micInUse = false
            show(L.t("Microphone access is off: recording the screen only.", "Micro non autorisé : seulement l'écran est enregistré.", "마이크 권한이 없어요. 화면만 녹화해요."))
        }
        do {
            let bundle = try Handoff.newBundle()
            bundleURL = bundle
            recordingHostStart = EventLog.hostNow()
            try await recorder.start(target: .displayUnderMouse, microphone: micInUse, quality: Settings.quality, to: Handoff.videoURL(in: bundle))
            eventLog.start(displayFrame: recorder.capturedFrame)
            log.info("recording started (microphone: \(self.micInUse, privacy: .public))")
            phase = .recording
            hud.show(.recording(since: Date(), microphone: micInUse))
            if micInUse { hud.startMeter { [weak self] in self?.recorder.microphoneLevel ?? 0 } }
            NSSound(named: "Tink")?.play()
            let limit = Settings.maxMinutes
            autoStop = Task { [weak self] in
                try? await Task.sleep(for: .seconds(limit * 60))
                guard !Task.isCancelled, let self, self.phase == .recording else { return }
                self.show(L.t("Stopped after \(Int(limit)) min (MaxMinutes).", "Arrêté au bout de \(Int(limit)) min (MaxMinutes).", "\(Int(limit))분이 지나 자동으로 멈췄어요(MaxMinutes)."))
                await self.stopRecording()
            }
        } catch {
            log.error("recording could not start: \(error.localizedDescription, privacy: .public)")
            phase = .idle
            removeIfEmpty(bundleURL)
            show(error.localizedDescription, seconds: 20)
            if case RecorderError.noPermission = error {
                hud.show(.problem(L.t("Allow WatchRecorder to record the screen, then reopen it", "Autorise WatchRecorder à enregistrer l'écran, puis relance-le", "WatchRecorder의 화면 녹화를 허용한 뒤 다시 열어 주세요"), settings: .screenRecording), hideAfter: 20)
                onboarding.show(at: .screen)
            } else {
                hud.show(.problem(L.t("Could not start: ", "Impossible de démarrer : ", "시작할 수 없어요: ") + error.localizedDescription, settings: nil), hideAfter: 8)
            }
        }
    }

    /// A bundle folder whose recording never started stays empty: remove it rather than leave clutter.
    private func removeIfEmpty(_ folder: URL?) {
        guard let folder, let items = try? FileManager.default.contentsOfDirectory(atPath: folder.path), items.isEmpty else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    private func stopRecording() async {
        autoStop?.cancel()
        guard let bundle = bundleURL, let startedAt = recorder.startedAt else {
            phase = .idle
            return
        }
        phase = .finishing
        let frontmostAtStop = NSWorkspace.shared.frontmostApplication
        hud.stopMeter()
        hud.show(.working(L.t("Saving…", "Enregistrement du fichier…", "저장하는 중…")))
        let recorded = eventLog.stop()
        do {
            let duration = try await recorder.stop()
            // t = 0 is the first video frame; events before it are clamped to 0.
            let videoStart = recorder.videoStartHostTime ?? recordingHostStart
            let video = VideoFacts(quality: Settings.quality, width: Int(recorder.videoSize.width), height: Int(recorder.videoSize.height), fps: Int(recorder.fps))
            try Handoff.writeBundle(bundle, createdAt: startedAt, duration: duration, video: video, events: recorded.map { $0.json(videoStart: videoStart) })
            phase = .transcribing
            hud.show(.working(micInUse ? L.t("Transcribing your voice…", "Transcription de ta voix…", "음성을 받아쓰는 중…") : L.t("Preparing for Claude…", "Préparation pour Claude…", "Claude에 보낼 준비 중…")))
            var transcript: String?
            do {
                let result = try await Handoff.finalize(bundle)
                log.info("finalize: \(result.status, privacy: .public)")
                transcript = Handoff.spokenText(result)
            } catch {
                log.error("finalize failed: \(error.localizedDescription, privacy: .public)")
                show(error.localizedDescription, seconds: 20)
            }
            try Handoff.publishLatest(path: bundle, startedAt: startedAt, duration: duration, transcript: transcript)
            let prompt = Handoff.prompt(recording: bundle, duration: duration, transcript: micInUse ? transcript : nil)
            Handoff.copyToClipboard(prompt)
            log.info("recording saved (\(Int(duration), privacy: .public) s, \(recorded.count, privacy: .public) events); prompt copied")
            lastPrompt = prompt
            onboarding.recordingFinished(summary: transcript.flatMap { $0.isEmpty ? nil : $0 } ?? L.t("(no speech)", "(sans parole)", "(음성 없음)"))
            dashboard.reload()
            phase = .idle
            NSSound(named: "Glass")?.play()
            let outcome = await Delivery.deliver(frontmostAtStop: frontmostAtStop, lastAIApp: tracker.lastAIApp)
            log.info("delivery: \(String(describing: outcome), privacy: .public)")
            switch outcome {
            case let .opened(app, true):
                hud.show(.done(L.t("Pasted into \(app): check it and send", "Collé dans \(app) : vérifie et envoie", "\(app)에 붙여 넣었어요. 확인하고 보내세요")), hideAfter: 4)
            case let .opened(app, false):
                hud.show(.done(L.t("Prompt ready in \(app): ⌘V then Enter", "Prompt prêt dans \(app) : ⌘V puis Entrée", "\(app)에 프롬프트 준비 완료: ⌘V 후 Enter")), hideAfter: 6)
            case let .copiedOnly(reason):
                let base = L.t("Prompt copied: ⌘V in Claude or Codex", "Prompt copié : ⌘V dans Claude ou Codex", "프롬프트를 복사했어요. Claude나 Codex에서 ⌘V")
                hud.show(.done(reason.map { "\(base) · \($0)" } ?? base), hideAfter: 6)
            }
        } catch {
            log.error("could not save the recording: \(error.localizedDescription, privacy: .public)")
            phase = .idle
            show(L.t("Could not save the recording: ", "Impossible d'enregistrer le fichier : ", "녹화를 저장할 수 없어요: ") + error.localizedDescription, seconds: 20)
            hud.show(.problem(L.t("Could not save the recording", "Impossible d'enregistrer le fichier", "녹화를 저장할 수 없어요"), settings: nil), hideAfter: 8)
        }
    }

    /// Re-registers the global shortcut (from the setup guide or the settings).
    private func applyHotKey(_ text: String) {
        hotKey?.unregister()
        Settings.setHotKey(text)
        let spec = Settings.hotKey
        hotKey = HotKey(spec) { [weak self] in self?.toggle() }
        hud.model.shortcut = spec.display
        log.info("shortcut changed to \(spec.display, privacy: .public) (\(self.hotKey == nil ? "NOT registered" : "registered", privacy: .public))")
        refresh()
    }

    /// "Send to my AI" from the library: same hand-over as at the end of a recording.
    private func send(_ recording: Recording) async {
        let transcript = recording.lines.isEmpty ? nil : recording.transcript
        try? Handoff.publishLatest(path: recording.url, startedAt: recording.createdAt, duration: recording.duration, transcript: transcript)
        Handoff.copyToClipboard(Handoff.prompt(recording: recording.url, duration: recording.duration, transcript: transcript))
        switch await Delivery.deliver(frontmostAtStop: nil, lastAIApp: tracker.lastAIApp) {
        case let .opened(app, true): hud.show(.done(L.t("Pasted into \(app)", "Collé dans \(app)", "\(app)에 붙여 넣었어요")), hideAfter: 4)
        case let .opened(app, false): hud.show(.done(L.t("Prompt ready in \(app): ⌘V then Enter", "Prompt prêt dans \(app) : ⌘V puis Entrée", "\(app)에 프롬프트 준비 완료: ⌘V 후 Enter")), hideAfter: 6)
        case .copiedOnly: hud.show(.done(L.t("Prompt copied (⌘V)", "Prompt copié (⌘V)", "프롬프트를 복사했어요(⌘V)")), hideAfter: 5)
        }
    }

    @objc private func openDashboard() {
        dashboard.show()
    }

    @objc private func openSettings() {
        dashboard.model.section = .settings
        dashboard.model.selected = nil
        dashboard.show()
    }

    /// Right-click on the Dock icon.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(toggleMenuItem())
        menu.addItem(item(L.t("Open WatchRecorder", "Ouvrir WatchRecorder", "WatchRecorder 열기"), #selector(openDashboard)))
        return menu
    }

    /// Quitting from the Dock, ⌘Q or macOS's "Quit & Reopen" while recording keeps the recording.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard phase == .recording else { return .terminateNow }
        Task {
            await stopRecording()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Opening the app again (Finder, Spotlight, Launchpad) while it runs shows its window,
    /// instead of doing nothing visible.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if onboarding.isVisible {
            onboarding.show()
        } else if let step = OnboardingStep.atLaunch(resume: Settings.onboardingResumeStep, screenAllowed: ScreenAccess.granted) {
            onboarding.show(at: step)
        } else {
            dashboard.show()
        }
        logStatusIconPlacement()
        return false
    }

    /// Logs whether the menu bar icon fits next to the notch (macOS hides icons that do not).
    private func logStatusIconPlacement() {
        let frame = statusItem?.button?.window?.frame ?? .zero
        let right = NSScreen.main?.auxiliaryTopRightArea
        log.info("status icon frame \(NSStringFromRect(frame), privacy: .public); right of notch \(right.map(NSStringFromRect) ?? "no notch", privacy: .public)")
    }

    /// Double-clicking a .watch bundle opens its video.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.pathExtension == "watch" {
            NSWorkspace.shared.open(Handoff.videoURL(in: url))
        }
    }

    // MARK: - Menu

    private func refresh() {
        guard let button = statusItem?.button else { return }
        let symbol: String
        switch phase {
        case .idle: symbol = "record.circle"
        case .starting, .recording: symbol = "record.circle.fill"
        case .finishing, .transcribing: symbol = "waveform"
        }
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "WatchRecorder")
        button.contentTintColor = phase == .recording ? .systemRed : nil
        button.title = phase == .recording ? " \(elapsed())" : ""
        updateTicker()
        statusItem?.menu = buildMenu()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let shortcut = Settings.hotKey.display
        let status: String
        switch phase {
        case .idle: status = L.t("Ready. Press \(shortcut) to record.", "Prêt. \(shortcut) pour enregistrer.", "준비됐어요. \(shortcut)로 녹화하세요.")
        case .starting: status = L.t("Starting…", "Démarrage…", "시작하는 중…")
        case .recording: status = L.t("Recording \(elapsed()). Press \(shortcut) to stop.", "Enregistrement \(elapsed()). \(shortcut) pour arrêter.", "녹화 중 \(elapsed()). \(shortcut)로 멈추세요.")
        case .finishing: status = L.t("Saving…", "Enregistrement du fichier…", "저장하는 중…")
        case .transcribing: status = L.t("Transcribing your voice…", "Transcription de ta voix…", "음성을 받아쓰는 중…")
        }
        menu.addItem(disabled(notice ?? status))
        menu.addItem(.separator())
        menu.addItem(item(L.t("Open WatchRecorder", "Ouvrir WatchRecorder", "WatchRecorder 열기"), #selector(openDashboard)))
        menu.addItem(toggleMenuItem())
        menu.addItem(item(L.t("Copy Last Prompt", "Copier le dernier prompt", "마지막 프롬프트 복사"), #selector(copyLastPrompt), enabled: lastPrompt != nil))
        menu.addItem(item(L.t("Show Recordings in Finder", "Afficher les enregistrements", "Finder에서 녹화 보기"), #selector(showRecordings)))
        menu.addItem(item(L.t("Permissions and Setup…", "Permissions et installation…", "권한 및 설정…"), #selector(showOnboarding)))
        menu.addItem(.separator())
        let mic = item(L.t("Record Microphone", "Enregistrer le micro", "마이크 녹음"), #selector(toggleMicrophone))
        mic.state = Settings.recordMicrophone ? .on : .off
        menu.addItem(mic)
        menu.addItem(sendToMenu())
        let paste = item(L.t("Paste Automatically (⌘V)", "Coller automatiquement (⌘V)", "자동으로 붙여넣기(⌘V)"), #selector(toggleAutoPaste))
        paste.state = Settings.autoPaste ? .on : .off
        menu.addItem(paste)
        menu.addItem(.separator())
        menu.addItem(item(L.t("Quit WatchRecorder", "Quitter WatchRecorder", "WatchRecorder 종료"), #selector(quit)))
        return menu
    }

    private func toggleMenuItem() -> NSMenuItem {
        let shortcut = Settings.hotKey.display
        let title = phase == .recording ? L.t("Stop Recording", "Arrêter l'enregistrement", "녹화 멈추기") : L.t("Start Recording", "Démarrer l'enregistrement", "녹화 시작")
        let toggleItem = NSMenuItem(title: "\(title)  (\(shortcut))", action: #selector(toggle), keyEquivalent: "")
        toggleItem.target = self
        toggleItem.isEnabled = phase == .idle || phase == .recording
        return toggleItem
    }

    private func item(_ title: String, _ action: Selector, enabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: enabled ? action : nil, keyEquivalent: "")
        item.target = self
        return item
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func copyLastPrompt() {
        if let lastPrompt { Handoff.copyToClipboard(lastPrompt) }
    }

    @objc private func showRecordings() {
        let folder = Settings.recordingsFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    private func sendToMenu() -> NSMenuItem {
        let parent = NSMenuItem(title: L.t("Send To", "Envoyer vers", "보낼 곳"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let choices: [(String, String)] = [
            ("auto", L.t("Auto (the AI app you were using)", "Auto (l'app d'IA que tu utilisais)", "자동(사용하던 AI 앱)")),
            ("claude", "Claude"),
            ("codex", "ChatGPT / Codex"),
            ("off", L.t("Clipboard only", "Presse-papiers seulement", "클립보드만")),
        ]
        for (value, title) in choices {
            let choice = NSMenuItem(title: title, action: #selector(chooseSendTo(_:)), keyEquivalent: "")
            choice.target = self
            choice.representedObject = value
            choice.state = Settings.sendTo == value ? .on : .off
            submenu.addItem(choice)
        }
        parent.submenu = submenu
        return parent
    }

    @objc private func chooseSendTo(_ sender: NSMenuItem) {
        if let value = sender.representedObject as? String { Settings.sendTo = value }
        refresh()
    }

    @objc private func toggleAutoPaste() {
        if Settings.autoPaste {
            Settings.autoPaste = false
        } else {
            Delivery.enableAutoPaste()
        }
        refresh()
    }

    @objc private func showOnboarding() {
        onboarding.show(at: .welcome)
    }

    @objc private func toggleMicrophone() {
        Settings.recordMicrophone.toggle()
        refresh()
    }

    @objc private func quit() {
        if phase == .recording {
            Task {
                await stopRecording()
                NSApp.terminate(nil)
            }
        } else {
            NSApp.terminate(nil)
        }
    }

    // MARK: - Helpers

    private func show(_ text: String, seconds: Double = 6) {
        notice = text
        refresh()
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.notice = nil
            self?.refresh()
        }
    }

    private func updateTicker() {
        if phase == .recording, ticker == nil {
            ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                MainActor.assumeIsolated { [weak self] in self?.refresh() }
            }
        } else if phase != .recording {
            ticker?.invalidate()
            ticker = nil
        }
    }

    private func elapsed() -> String {
        guard let startedAt = recorder.startedAt else { return "0:00" }
        return Handoff.clock(Date().timeIntervalSince(startedAt))
    }

}
