import AppKit
import SwiftUI

/// `WatchRecorder --render-ui <out dir> <recordings folder>`: draws every screen offscreen and saves
/// PNGs, to check the interface without recording anyone's screen.
@MainActor
enum RenderUI {
    static func run(outDir: URL, library folder: URL) async -> Int32 {
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let onboarding = OnboardingController()
        onboarding.model.library.folder = folder
        onboarding.model.library.reload()
        onboarding.model.refreshPermissions()
        // Sample AI apps, so the pictures do not depend on what is installed on this Mac.
        onboarding.model.clients = [
            AIClientStatus(client: "claude-code", label: "Claude Code", action: "ok"),
            AIClientStatus(client: "codex", label: "Codex", action: "ok"),
            AIClientStatus(client: "claude-desktop", label: "Claude Desktop", action: "add"),
            AIClientStatus(client: "cursor", label: "Cursor", action: "absent"),
        ]
        for appearance in Appearance.allCases {
            for step in OnboardingStep.allCases {
                onboarding.model.step = step
                if step == .microphone { onboarding.model.levels = (0..<24).map { 0.25 + 0.6 * abs(sin(Double($0) / 3)) } }
                // The Screen Recording step as a new user first sees it.
                let granted = onboarding.model.granted
                if step == .screen { onboarding.model.granted[.screen] = false }
                await save(OnboardingView(controller: onboarding, model: onboarding.model), size: CGSize(width: 640, height: 620), appearance: appearance, to: outDir.appendingPathComponent("onboarding-\(step.rawValue + 1)-\(appearance.rawValue).png"))
                onboarding.model.granted = granted
            }
        }
        let dashboard = DashboardController(onboarding: onboarding)
        let model = dashboard.model
        model.rendering = true
        model.library.folder = folder
        model.library.reload()
        await preloadThumbnails(model.library.recordings)
        let size = CGSize(width: 1120, height: 720)
        // Pages that scroll in the app are drawn taller, so the whole page is visible.
        let tall = CGSize(width: 1120, height: 1300)
        for appearance in Appearance.allCases {
            model.section = .recordings
            model.selected = nil
            await save(DashboardView(model: model, onboarding: onboarding), size: tall, appearance: appearance, to: outDir.appendingPathComponent("dashboard-library-\(appearance.rawValue).png"))
            model.selected = model.library.recordings.first
            await save(DashboardView(model: model, onboarding: onboarding), size: size, appearance: appearance, to: outDir.appendingPathComponent("dashboard-detail-\(appearance.rawValue).png"))
            model.selected = nil
            model.section = .settings
            await save(DashboardView(model: model, onboarding: onboarding), size: CGSize(width: 1120, height: 1500), appearance: appearance, to: outDir.appendingPathComponent("dashboard-settings-\(appearance.rawValue).png"))
        }
        // Korean pass: the screens with the most text.
        let savedLanguage = L.override
        L.override = .ko
        for step in [OnboardingStep.welcome, .quality, .connect] {
            onboarding.model.step = step
            await save(OnboardingView(controller: onboarding, model: onboarding.model), size: CGSize(width: 640, height: 620), appearance: .light, to: outDir.appendingPathComponent("ko-onboarding-\(step.rawValue + 1).png"))
        }
        model.section = .recordings
        model.selected = nil
        await save(DashboardView(model: model, onboarding: onboarding), size: tall, appearance: .light, to: outDir.appendingPathComponent("ko-dashboard-library.png"))
        model.selected = model.library.recordings.first
        await save(DashboardView(model: model, onboarding: onboarding), size: size, appearance: .light, to: outDir.appendingPathComponent("ko-dashboard-detail.png"))
        L.override = savedLanguage
        print("rendered to \(outDir.path)")
        return 0
    }

    private static func preloadThumbnails(_ recordings: [Recording]) async {
        for recording in recordings {
            _ = await Thumbnails.shared.image(for: recording.videoURL, at: recording.posterTime)
            _ = await Thumbnails.shared.image(for: recording.videoURL, at: recording.posterTime, maxWidth: 1200)
            for t in recording.keyframes { _ = await Thumbnails.shared.image(for: recording.videoURL, at: t, maxWidth: 220) }
        }
    }

    enum Appearance: String, CaseIterable {
        case light, dark
        var name: NSAppearance.Name { self == .light ? .aqua : .darkAqua }
    }

    /// Hosts the view in an offscreen window (so AppKit-backed parts draw too) and caches its display.
    private static func save(_ view: some View, size: CGSize, appearance: Appearance, to url: URL) async {
        let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -10_000, y: -10_000), size: size), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: appearance.name)
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).environment(\.renderingSnapshot, true))
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        window.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(700))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        window.orderOut(nil)
    }
}
