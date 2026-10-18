import AppKit
import SwiftUI

/// Strings in French when the system prefers French, English otherwise.
enum L {
    static let french = Locale.preferredLanguages.first?.hasPrefix("fr") ?? false
    static func t(_ en: String, _ fr: String) -> String { french ? fr : en }
}

/// What the floating pill shows.
enum HUDState: Equatable {
    case hidden
    case starting
    case recording(since: Date, microphone: Bool)
    case working(String)
    case done(String)
    case problem(String, settings: SettingsPane?)
}

/// System Settings panes the pill can open.
enum SettingsPane: Equatable {
    case screenRecording
    case accessibility

    var url: URL? {
        switch self {
        case .screenRecording: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        case .accessibility: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        }
    }
}

@MainActor @Observable
final class HUDModel {
    var state: HUDState = .hidden
    /// Recent microphone levels (0...1), oldest first.
    var levels: [Double] = Array(repeating: 0, count: HUDModel.barCount)
    static let barCount = 14
    var shortcut = ""
    var onStop: () -> Void = {}
    var onOpenSettings: (SettingsPane) -> Void = { _ in }
}

/// A small pill near the bottom of the screen, like dictation apps show: it says that a
/// recording is running, how long it has run, and that your voice is heard.
/// It never takes focus, and the recorder excludes it from the video.
@MainActor
final class HUDController {
    let model = HUDModel()
    private let panel: NSPanel
    private let host: NSHostingView<HUDView>
    private var hideTask: Task<Void, Never>?
    private var meter: Timer?

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 52), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        host = NSHostingView(rootView: HUDView(model: model))
        host.frame = panel.contentRect(forFrameRect: panel.frame)
        panel.contentView = host
    }

    /// Shows a state; `hideAfter` seconds later the pill fades away (nil keeps it).
    func show(_ state: HUDState, hideAfter: Double? = nil) {
        hideTask?.cancel()
        model.state = state
        fitAndPlace()
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        // SwiftUI may lay the new content out on the next pass: fit again then.
        DispatchQueue.main.async { [weak self] in self?.fitAndPlace() }
        guard let hideAfter else { return }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(hideAfter))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    func hide() {
        hideTask?.cancel()
        stopMeter()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.panel.alphaValue == 0 else { return }
                self.panel.orderOut(nil)
                self.model.state = .hidden
            }
        })
    }

    /// Polls `level` (0...1) about 20 times a second to animate the bars.
    func startMeter(level: @escaping @MainActor () -> Double) {
        stopMeter()
        model.levels = Array(repeating: 0, count: HUDModel.barCount)
        meter = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.model.levels = Array(self.model.levels.dropFirst()) + [level()]
            }
        }
    }

    func stopMeter() {
        meter?.invalidate()
        meter = nil
    }

    /// Sizes the panel to its content (so text is never cut), then puts it at the bottom
    /// center of the screen under the mouse, above the Dock.
    private func fitAndPlace() {
        host.layoutSubtreeIfNeeded()
        let width = min(760, max(180, ceil(host.fittingSize.width) + 8))
        panel.setContentSize(NSSize(width: width, height: 52))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 52)
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let area = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: area.midX - size.width / 2, y: area.minY + 28))
        // Clicks reach the pill only when it has something to click.
        switch model.state {
        case .recording: panel.ignoresMouseEvents = false
        case let .problem(_, pane): panel.ignoresMouseEvents = pane == nil
        default: panel.ignoresMouseEvents = true
        }
    }
}

struct HUDView: View {
    let model: HUDModel

    var body: some View {
        HStack(spacing: 10) {
            content
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
        .background(.ultraThinMaterial, in: Capsule())
        .background(Color.black.opacity(0.55), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        .foregroundStyle(.white)
        .fixedSize()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.15), value: model.state)
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .hidden:
            EmptyView()
        case .starting:
            ProgressView().controlSize(.small).tint(.white)
            Text(L.t("Starting…", "Démarrage…")).font(.system(size: 13, weight: .medium))
        case let .recording(since, microphone):
            Button(action: model.onStop) {
                HStack(spacing: 10) {
                    PulsingDot()
                    if microphone { Bars(levels: model.levels) } else { Text(L.t("no mic", "sans micro")).font(.system(size: 11)).opacity(0.7) }
                    Text(since, style: .timer).font(.system(size: 13, weight: .semibold).monospacedDigit())
                    Text(model.shortcut).font(.system(size: 11, weight: .medium)).opacity(0.6)
                    Image(systemName: "stop.fill").font(.system(size: 11)).opacity(0.85)
                }
            }
            .buttonStyle(.plain)
            .help(L.t("Stop recording", "Arrêter l'enregistrement"))
        case let .working(text):
            ProgressView().controlSize(.small).tint(.white)
            Text(text).font(.system(size: 13, weight: .medium))
        case let .done(text):
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text(text).font(.system(size: 13, weight: .medium))
        case let .problem(text, pane):
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text(text).font(.system(size: 12, weight: .medium)).lineLimit(1)
            if let pane {
                Button(L.t("Open Settings", "Ouvrir les Réglages")) { model.onOpenSettings(pane) }
                    .buttonStyle(.borderedProminent).controlSize(.small)
            }
        }
    }
}

private struct PulsingDot: View {
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(Color.red)
            .frame(width: 10, height: 10)
            .opacity(dim ? 0.35 : 1)
            .onAppear { withAnimation(.easeInOut(duration: 0.8).repeatForever()) { dim = true } }
    }
}

private struct Bars: View {
    let levels: [Double]

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 3, height: 3 + 17 * level)
            }
        }
        .frame(height: 20)
        .animation(.linear(duration: 0.05), value: levels)
    }
}
