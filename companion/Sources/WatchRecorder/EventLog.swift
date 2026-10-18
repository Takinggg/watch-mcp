import AppKit
import ApplicationServices
import CoreMedia

/// One input event, in the bundle format (timeline.json). `t` is set when the recording stops.
struct RecordedEvent: Equatable {
    enum Kind: Equatable {
        case click(button: String, x: Double, y: Double)
        case typing(duration: Double, keys: Int)
        case shortcut(modifiers: [String])
        case app(name: String)
    }

    /// Host-clock seconds (same clock as NSEvent.timestamp and screen sample timestamps).
    var hostTime: Double
    var kind: Kind
    var app: String?

    /// JSON object for timeline.json, with `t` relative to the first video frame.
    func json(videoStart: Double) -> [String: Any] {
        var out: [String: Any] = ["t": Self.round(max(0, hostTime - videoStart))]
        switch kind {
        case let .click(button, x, y):
            out["type"] = "click"; out["button"] = button; out["x"] = Self.round(x); out["y"] = Self.round(y)
        case let .typing(duration, keys):
            out["type"] = "typing"; out["duration"] = Self.round(duration); out["keys"] = keys
        case let .shortcut(modifiers):
            out["type"] = "shortcut"; out["modifiers"] = modifiers
        case let .app(name):
            out["type"] = "app"; out["name"] = name
        }
        // App switches carry the app as their subject; other events say where they happened.
        if case .app = kind {} else if let app { out["app"] = app }
        return out
    }

    private static func round(_ value: Double) -> Double { (value * 1000).rounded() / 1000 }
}

/// Position of a global screen point inside the recorded display, as fractions from its top-left
/// corner; nil when the point is outside it. AppKit screen coordinates start at the bottom-left.
func normalizedPoint(_ point: CGPoint, in frame: CGRect) -> CGPoint? {
    guard frame.width > 0, frame.height > 0 else { return nil }
    let x = (point.x - frame.minX) / frame.width
    let y = 1 - (point.y - frame.minY) / frame.height
    guard (0...1).contains(x), (0...1).contains(y) else { return nil }
    return CGPoint(x: x, y: y)
}

/// Turns key presses into typing bursts (count and duration only) and shortcuts (modifiers only).
struct KeyAggregator {
    /// A pause longer than this starts a new typing burst.
    static let burstGap = 1.5
    private(set) var events: [RecordedEvent] = []
    private var burstStart: Double?
    private var burstLast = 0.0
    private var burstKeys = 0
    private var burstApp: String?

    /// `modifiers` are the command/control/option keys held; shift alone counts as typing.
    mutating func key(at time: Double, modifiers: [String], app: String?) {
        if !modifiers.isEmpty {
            flush()
            events.append(RecordedEvent(hostTime: time, kind: .shortcut(modifiers: modifiers), app: app))
            return
        }
        if burstStart != nil, time - burstLast <= Self.burstGap, app == burstApp {
            burstLast = time
            burstKeys += 1
        } else {
            flush()
            burstStart = time
            burstLast = time
            burstKeys = 1
            burstApp = app
        }
    }

    mutating func flush() {
        guard let start = burstStart else { return }
        events.append(RecordedEvent(hostTime: start, kind: .typing(duration: burstLast - start, keys: burstKeys), app: burstApp))
        burstStart = nil
        burstKeys = 0
    }
}

/// Records clicks, typing bursts, shortcuts and app switches while a recording runs.
/// Never records which keys were pressed. Keys are only observed when the user has already
/// trusted WatchRecorder for Accessibility; the app never asks for it.
@MainActor
final class EventLog {
    private static let maxEvents = 50_000
    private var monitors: [Any] = []
    private var appObserver: NSObjectProtocol?
    private var events: [RecordedEvent] = []
    private var keys = KeyAggregator()
    private var frame = CGRect.zero

    static func hostNow() -> Double {
        CMClockGetTime(CMClockGetHostTimeClock()).seconds
    }

    /// `displayFrame`: the recorded display in AppKit screen coordinates.
    func start(displayFrame: CGRect) {
        frame = displayFrame
        events = []
        keys = KeyAggregator()
        if let name = NSWorkspace.shared.frontmostApplication?.localizedName {
            append(RecordedEvent(hostTime: Self.hostNow(), kind: .app(name: name), app: nil))
        }
        let clicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.click(event) }
        }
        if let clicks { monitors.append(clicks) }
        if AXIsProcessTrusted(), let typing = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.key(event) }
        }) {
            monitors.append(typing)
        }
        appObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let name = app?.localizedName ?? "unknown app"
            MainActor.assumeIsolated { self?.append(RecordedEvent(hostTime: Self.hostNow(), kind: .app(name: name), app: nil)) }
        }
    }

    /// Stops observing and returns the events in time order.
    func stop() -> [RecordedEvent] {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        if let appObserver { NSWorkspace.shared.notificationCenter.removeObserver(appObserver) }
        appObserver = nil
        keys.flush()
        let all = (events + keys.events).sorted { $0.hostTime < $1.hostTime }
        events = []
        return all
    }

    private func click(_ event: NSEvent) {
        guard let point = normalizedPoint(NSEvent.mouseLocation, in: frame) else { return }
        let button: String
        switch event.type {
        case .leftMouseDown: button = "left"
        case .rightMouseDown: button = "right"
        default: button = "other"
        }
        let app = NSWorkspace.shared.frontmostApplication?.localizedName
        append(RecordedEvent(hostTime: event.timestamp, kind: .click(button: button, x: point.x, y: point.y), app: app))
    }

    private func key(_ event: NSEvent) {
        guard events.count + keys.events.count < Self.maxEvents else { return }
        var modifiers: [String] = []
        let flags = event.modifierFlags
        if flags.contains(.command) { modifiers.append("cmd") }
        if flags.contains(.control) { modifiers.append("ctrl") }
        if flags.contains(.option) { modifiers.append("opt") }
        keys.key(at: event.timestamp, modifiers: modifiers, app: NSWorkspace.shared.frontmostApplication?.localizedName)
    }

    private func append(_ event: RecordedEvent) {
        guard events.count < Self.maxEvents else { return }
        events.append(event)
    }
}
