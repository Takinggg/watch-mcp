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
        let spec = Settings.hotKey
        hotKey = HotKey(spec) { [weak self] in self?.toggle() }
        log.info("launched; shortcut \(spec.display, privacy: .public) \(self.hotKey == nil ? "NOT registered" : "registered", privacy: .public); watch-mcp command: \(Settings.watchMcpCommand, privacy: .public)")
        hud.model.shortcut = spec.display
        hud.model.onStop = { [weak self] in self?.toggle() }
        hud.model.onOpenSettings = { [weak self] pane in
            self?.hud.hide()
            if let url = pane.url { NSWorkspace.shared.open(url) }
        }
        if hotKey == nil {
            show(L.t("\(spec.display) is used by another app. Pick another shortcut (see README).", "\(spec.display) est déjà pris par une autre app. Choisis un autre raccourci (voir README)."), seconds: 30)
            hud.show(.problem(L.t("Shortcut \(spec.display) is taken by another app", "Raccourci \(spec.display) déjà pris par une autre app"), settings: nil), hideAfter: 8)
        } else if !CGPreflightScreenCaptureAccess() {
            // New user (or permission removed): walk through the permissions.
            onboarding.show()
        } else {
            // A short hello so the user sees the app is there and knows the shortcut.
            hud.show(.done(L.t("WatchRecorder is ready: press \(spec.display) to record", "WatchRecorder est prêt : \(spec.display) pour enregistrer")), hideAfter: 4)
        }
        recorder.onUnexpectedStop = { [weak self] error in
            log.error("capture stopped unexpectedly: \(error.localizedDescription, privacy: .public)")
            self?.phase = .idle
            self?.show(L.t("Recording stopped: ", "Enregistrement arrêté : ") + error.localizedDescription)
            self?.hud.show(.problem(L.t("Recording stopped", "Enregistrement arrêté"), settings: nil), hideAfter: 6)
        }
        refresh()
    }

    @objc func toggle() {
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
            show(L.t("Microphone access is off: recording the screen only.", "Micro non autorisé : seulement l'écran est enregistré."))
        }
        do {
            let bundle = try Handoff.newBundle()
            bundleURL = bundle
            recordingHostStart = EventLog.hostNow()
            try await recorder.start(target: .displayUnderMouse, microphone: micInUse, to: Handoff.videoURL(in: bundle))
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
                self.show(L.t("Stopped after \(Int(limit)) min (MaxMinutes).", "Arrêté au bout de \(Int(limit)) min (MaxMinutes)."))
                await self.stopRecording()
            }
        } catch {
            log.error("recording could not start: \(error.localizedDescription, privacy: .public)")
            phase = .idle
            removeIfEmpty(bundleURL)
            show(error.localizedDescription, seconds: 20)
            if case RecorderError.noPermission = error {
                hud.show(.problem(L.t("Allow WatchRecorder to record the screen, then reopen it", "Autorise WatchRecorder à enregistrer l'écran, puis relance-le"), settings: .screenRecording), hideAfter: 20)
                onboarding.show()
            } else {
                hud.show(.problem(L.t("Could not start: ", "Impossible de démarrer : ") + error.localizedDescription, settings: nil), hideAfter: 8)
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
        hud.show(.working(L.t("Saving…", "Enregistrement du fichier…")))
        let recorded = eventLog.stop()
        do {
            let duration = try await recorder.stop()
            // t = 0 is the first video frame; events before it are clamped to 0.
            let videoStart = recorder.videoStartHostTime ?? recordingHostStart
            try Handoff.writeBundle(bundle, createdAt: startedAt, duration: duration, events: recorded.map { $0.json(videoStart: videoStart) })
            phase = .transcribing
            hud.show(.working(micInUse ? L.t("Transcribing your voice…", "Transcription de ta voix…") : L.t("Preparing for Claude…", "Préparation pour Claude…")))
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
            phase = .idle
            NSSound(named: "Glass")?.play()
            let outcome = await AutoPaste.deliver(frontmostAtStop: frontmostAtStop)
            log.info("paste: \(String(describing: outcome), privacy: .public)")
            switch outcome {
            case let .pasted(app):
                hud.show(.done(L.t("Pasted into \(app): check it and send", "Collé dans \(app) : vérifie et envoie")), hideAfter: 4)
            case .needsAccessibility:
                hud.show(.problem(L.t("To paste by itself, allow WatchRecorder in Accessibility (prompt copied: ⌘V)", "Pour coller tout seul, autorise WatchRecorder dans Accessibilité (prompt copié : ⌘V)"), settings: .accessibility), hideAfter: 15)
            case let .copiedOnly(reason):
                let base = L.t("Prompt copied: paste it into Claude (⌘V)", "Prompt copié : colle-le dans Claude (⌘V)")
                hud.show(.done(reason.map { "\(base) · \($0)" } ?? base), hideAfter: 5)
            }
        } catch {
            log.error("could not save the recording: \(error.localizedDescription, privacy: .public)")
            phase = .idle
            show(L.t("Could not save the recording: ", "Impossible d'enregistrer le fichier : ") + error.localizedDescription, seconds: 20)
            hud.show(.problem(L.t("Could not save the recording", "Impossible d'enregistrer le fichier"), settings: nil), hideAfter: 8)
        }
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
        case .idle: status = L.t("Ready. Press \(shortcut) to record.", "Prêt. \(shortcut) pour enregistrer.")
        case .starting: status = L.t("Starting…", "Démarrage…")
        case .recording: status = L.t("Recording \(elapsed()). Press \(shortcut) to stop.", "Enregistrement \(elapsed()). \(shortcut) pour arrêter.")
        case .finishing: status = L.t("Saving…", "Enregistrement du fichier…")
        case .transcribing: status = L.t("Transcribing your voice…", "Transcription de ta voix…")
        }
        menu.addItem(disabled(notice ?? status))
        menu.addItem(.separator())
        let toggleTitle = phase == .recording ? L.t("Stop Recording", "Arrêter l'enregistrement") : L.t("Start Recording", "Démarrer l'enregistrement")
        let toggleItem = NSMenuItem(title: "\(toggleTitle)  (\(shortcut))", action: #selector(toggle), keyEquivalent: "")
        toggleItem.target = self
        toggleItem.isEnabled = phase == .idle || phase == .recording
        menu.addItem(toggleItem)
        menu.addItem(item(L.t("Copy Last Prompt", "Copier le dernier prompt"), #selector(copyLastPrompt), enabled: lastPrompt != nil))
        menu.addItem(item(L.t("Show Recordings in Finder", "Afficher les enregistrements"), #selector(showRecordings)))
        menu.addItem(item(L.t("Permissions and Setup…", "Permissions et installation…"), #selector(showOnboarding)))
        menu.addItem(.separator())
        let mic = item(L.t("Record Microphone", "Enregistrer le micro"), #selector(toggleMicrophone))
        mic.state = Settings.recordMicrophone ? .on : .off
        menu.addItem(mic)
        menu.addItem(.separator())
        menu.addItem(item(L.t("Quit WatchRecorder", "Quitter WatchRecorder"), #selector(quit)))
        return menu
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

    @objc private func showOnboarding() {
        onboarding.show()
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
