import AppKit
import AVFoundation
import os
import ScreenCaptureKit

enum RecorderError: LocalizedError {
    case noDisplay
    case noPermission
    case notRecording
    case finishTimedOut

    var errorDescription: String? {
        switch self {
        case .noDisplay: "No display to record."
        case .noPermission: L.t("WatchRecorder needs Screen Recording permission (System Settings > Privacy & Security > Screen & System Audio Recording).", "WatchRecorder a besoin de la permission Enregistrement de l'écran (Réglages Système > Confidentialité et sécurité > Enregistrement de l'écran et de l'audio système).", "WatchRecorder에 화면 녹화 권한이 필요해요(시스템 설정 > 개인정보 보호 및 보안 > 화면 및 시스템 오디오 녹화).")
        case .notRecording: "Not recording."
        case .finishTimedOut: "The recording did not finish writing in time."
        }
    }
}

/// What to capture: the display under the mouse pointer, or one window (used by the self-test).
enum CaptureTarget {
    case displayUnderMouse
    case window(CGWindowID)
}

/// Whether this process may record the screen right now.
enum ScreenAccess {
    /// CGPreflightScreenCaptureAccess keeps the answer it had at launch in a running process
    /// (measured on macOS 26), while other apps' window titles become readable as soon as the user
    /// allows Screen Recording: checking both lets setup go on without a relaunch.
    static var granted: Bool { CGPreflightScreenCaptureAccess() || otherAppWindowTitlesVisible() }

    /// Window titles of other apps are hidden from apps without Screen Recording access.
    static func otherAppWindowTitlesVisible() -> Bool {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
        let me = ProcessInfo.processInfo.processIdentifier
        return windows.contains { window in
            (window[kCGWindowOwnerPID as String] as? Int32) != me
                && (window[kCGWindowLayer as String] as? Int) == 0
                && !((window[kCGWindowName as String] as? String) ?? "").isEmpty
        }
    }
}

/// Records the screen (and optionally the microphone) straight to a .mov file
/// with SCRecordingOutput, so video and voice stay in sync.
@MainActor
final class Recorder: NSObject {
    private var stream: SCStream?
    private var output: SCRecordingOutput?
    private var finished: CheckedContinuation<Void, Error>?
    /// Bumped on every stop, so a late timeout from an earlier stop cannot end a newer one.
    private var generation = 0
    /// Called when capture ends on its own (permission revoked, display unplugged...).
    var onUnexpectedStop: ((Error) -> Void)?
    private(set) var fileURL: URL?
    private(set) var startedAt: Date?
    /// The recorded area in AppKit screen coordinates (to place clicks in the video frame).
    private(set) var capturedFrame = CGRect.zero
    /// Host-clock time of the first video frame: t = 0 of the bundle timeline.
    var videoStartHostTime: Double? { sink.firstFrameTime }
    /// Latest microphone level, 0...1 (for the on-screen meter).
    var microphoneLevel: Double { sink.level }

    private let sink = FirstFrameClock()
    private let sinkQueue = DispatchQueue(label: "io.github.takinggg.watchrecorder.sink")

    /// Size and frame rate of the current recording (written to the bundle manifest).
    private(set) var videoSize = CGSize.zero
    private(set) var fps: Int32 = 30

    func start(target: CaptureTarget, microphone: Bool, quality: Quality, to url: URL) async throws {
        guard ScreenAccess.granted else {
            // Shows the system prompt the first time; the user then enables the app in System Settings.
            CGRequestScreenCaptureAccess()
            throw RecorderError.noPermission
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let (filter, pointSize, scale, frame) = try makeFilter(content: content, target: target)
        capturedFrame = frame
        sink.reset()

        let config = SCStreamConfiguration()
        let factor = min(1.0, quality.maxLongEdge / max(pointSize.width * scale, pointSize.height * scale))
        config.width = Recorder.even(pointSize.width * scale * factor)
        config.height = Recorder.even(pointSize.height * scale * factor)
        config.minimumFrameInterval = CMTime(value: 1, timescale: quality.fps)
        videoSize = CGSize(width: config.width, height: config.height)
        fps = quality.fps
        config.showsCursor = true
        config.queueDepth = 6
        config.capturesAudio = false
        config.captureMicrophone = microphone

        let recording = SCRecordingOutputConfiguration()
        recording.outputURL = url
        recording.outputFileType = .mov
        recording.videoCodecType = .h264

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        // SCRecordingOutput writes the file. These outputs note when the first frame arrives (the
        // timeline's t = 0) and keep ScreenCaptureKit from logging "stream output not found".
        try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: sinkQueue)
        if microphone { try stream.addStreamOutput(sink, type: .microphone, sampleHandlerQueue: sinkQueue) }
        let output = SCRecordingOutput(configuration: recording, delegate: self)
        try stream.addRecordingOutput(output)
        try await stream.startCapture()
        self.stream = stream
        self.output = output
        self.fileURL = url
        self.startedAt = Date()
    }

    /// Stops capture and waits until the file is fully written. Returns its duration in seconds.
    func stop() async throws -> Double {
        guard let stream, let output else { throw RecorderError.notRecording }
        let duration = CMTimeGetSeconds(output.recordedDuration)
        generation += 1
        let current = generation
        defer {
            self.stream = nil
            self.output = nil
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            finished = continuation
            Task { @MainActor in
                do {
                    try await stream.stopCapture()
                } catch {
                    self.resumeFinished(throwing: error)
                }
                try? await Task.sleep(for: .seconds(15))
                if self.generation == current { self.resumeFinished(throwing: RecorderError.finishTimedOut) }
            }
        }
        let finalDuration = CMTimeGetSeconds(output.recordedDuration)
        return finalDuration.isFinite && finalDuration > 0 ? finalDuration : (duration.isFinite ? duration : 0)
    }

    var isRecording: Bool { stream != nil }

    private func resumeFinished(throwing error: Error? = nil) {
        guard let continuation = finished else { return }
        finished = nil
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }

    private func makeFilter(content: SCShareableContent, target: CaptureTarget) throws -> (SCContentFilter, CGSize, CGFloat, CGRect) {
        switch target {
        case .window(let id):
            guard let window = content.windows.first(where: { $0.windowID == id }) else { throw RecorderError.noDisplay }
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            return (SCContentFilter(desktopIndependentWindow: window), window.frame.size, scale, .zero)
        case .displayUnderMouse:
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
            let number = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            let display = content.displays.first { $0.displayID == number?.uint32Value } ?? content.displays.first
            guard let display else { throw RecorderError.noDisplay }
            // WatchRecorder's own windows (the floating pill, its menu) stay out of the video.
            let ownApp = content.applications.first { $0.processID == ProcessInfo.processInfo.processIdentifier }
            let filter = ownApp.map { SCContentFilter(display: display, excludingApplications: [$0], exceptingWindows: []) }
                ?? SCContentFilter(display: display, excludingWindows: [])
            let frame = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID }?.frame ?? .zero
            return (filter, CGSize(width: display.width, height: display.height), screen?.backingScaleFactor ?? 2, frame)
        }
    }

    private static func even(_ value: CGFloat) -> Int {
        max(2, Int(value / 2) * 2)
    }
}

extension Recorder: SCStreamDelegate, SCRecordingOutputDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            if self.finished != nil {
                self.resumeFinished(throwing: error)
            } else if self.stream != nil {
                self.stream = nil
                self.output = nil
                self.onUnexpectedStop?(error)
            }
        }
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in self.resumeFinished() }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        Task { @MainActor in self.resumeFinished(throwing: error) }
    }
}

/// Receives sample buffers: keeps the timestamp of the first screen frame and the current
/// microphone level, and drops the buffers (the recording output does the writing).
final class FirstFrameClock: NSObject, SCStreamOutput, Sendable {
    private let first = OSAllocatedUnfairLock<Double?>(initialState: nil)
    private let micLevel = OSAllocatedUnfairLock<Double>(initialState: 0)

    var firstFrameTime: Double? { first.withLock { $0 } }
    var level: Double { micLevel.withLock { $0 } }

    func reset() {
        first.withLock { $0 = nil }
        micLevel.withLock { $0 = 0 }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .screen:
            let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
            guard time.isFinite else { return }
            first.withLock { if $0 == nil { $0 = time } }
        case .microphone:
            guard let rms = Self.rms(sampleBuffer) else { return }
            // -50 dBFS (silence) ... 0 dBFS mapped to 0...1.
            let db = 20 * log10(max(rms, 1e-6))
            let value = min(1, max(0, (db + 50) / 50))
            micLevel.withLock { $0 = value }
        default:
            break
        }
    }

    /// Root mean square of the first contiguous block of 32-bit float or 16-bit integer samples.
    static func rms(_ sampleBuffer: CMSampleBuffer) -> Double? {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: &length, totalLengthOut: nil, dataPointerOut: &pointer) == kCMBlockBufferNoErr,
              let pointer, length > 0 else { return nil }
        let raw = UnsafeRawPointer(pointer)
        var sum = 0.0
        var count = 0
        if asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0, asbd.mBitsPerChannel == 32 {
            count = length / 4
            let samples = raw.bindMemory(to: Float.self, capacity: count)
            for i in 0..<count { sum += Double(samples[i] * samples[i]) }
        } else if asbd.mBitsPerChannel == 16 {
            count = length / 2
            let samples = raw.bindMemory(to: Int16.self, capacity: count)
            for i in 0..<count { let v = Double(samples[i]) / 32768; sum += v * v }
        }
        return count > 0 ? (sum / Double(count)).squareRoot() : nil
    }
}
