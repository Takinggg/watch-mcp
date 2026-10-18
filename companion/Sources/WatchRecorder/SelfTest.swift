import AppKit
import AVFoundation

/// Checks that can run without touching the user's screen, microphone or clipboard.
@MainActor
enum SelfTest {
    /// Records a window this process draws itself (moving square + counter), never the rest of the screen.
    /// Exit codes: 0 ok, 3 no Screen Recording permission (the system prompt is not triggered), 1 failure.
    static func recordOwnWindow(seconds: Double, to output: URL) async -> Int32 {
        guard CGPreflightScreenCaptureAccess() else {
            print("{\"status\":\"no-permission\"}")
            return 3
        }
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 640, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "WatchRecorder self-test"
        let view = TestPatternView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        window.contentView = view
        window.orderFrontRegardless()
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { _ in
            MainActor.assumeIsolated { view.tick() }
        }
        defer { timer.invalidate() }
        try? await Task.sleep(for: .milliseconds(500))
        let recorder = Recorder()
        do {
            try await recorder.start(target: .window(CGWindowID(window.windowNumber)), microphone: false, quality: .light, to: output)
            try await Task.sleep(for: .seconds(seconds))
            let duration = try await recorder.stop()
            print("{\"status\":\"ok\",\"path\":\"\(output.path)\",\"duration\":\(duration)}")
            return 0
        } catch {
            print("{\"status\":\"error\",\"message\":\"\(error.localizedDescription)\"}")
            return 1
        }
    }

    /// Runs everything that happens after a recording stops (finalize, state file, prompt) on an
    /// existing .watch bundle, and prints the prompt instead of copying it.
    /// Honors WATCH_MCP_STATE_DIR so tests do not overwrite the real state.
    static func handoff(bundle: URL) async -> Int32 {
        do {
            let asset = AVURLAsset(url: Handoff.videoURL(in: bundle))
            let duration = try await asset.load(.duration).seconds
            let result = try await Handoff.finalize(bundle)
            let transcript = Handoff.spokenText(result)
            try Handoff.publishLatest(path: bundle, startedAt: Date(), duration: duration, transcript: transcript)
            print(Handoff.prompt(recording: bundle, duration: duration, transcript: transcript))
            return 0
        } catch {
            print("handoff failed: \(error.localizedDescription) (\(String(describing: error)))")
            return 1
        }
    }
}

/// A moving square and a frame counter, so the self-test recording has visible change.
final class TestPatternView: NSView {
    private var frameCount = 0

    func tick() {
        frameCount += 1
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
        bounds.fill()
        let x = CGFloat((frameCount * 6) % Int(bounds.width - 60))
        NSColor.systemOrange.setFill()
        NSRect(x: x, y: 170, width: 60, height: 60).fill()
        let text = "WatchRecorder self-test  frame \(frameCount)" as NSString
        text.draw(at: NSPoint(x: 24, y: 340), withAttributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 22, weight: .medium),
            .foregroundColor: NSColor.white,
        ])
    }
}
