import AppKit
import AVFoundation

/// One recording bundle as read from disk (the format is specified in the README).
struct Recording: Identifiable, Hashable {
    struct Line: Hashable {
        let start: Double
        let end: Double
        let text: String
    }

    struct Event: Hashable {
        let t: Double
        let type: String
        let text: String
        let symbol: String
    }

    let url: URL
    let videoURL: URL
    let createdAt: Date
    let duration: Double
    let quality: Quality?
    let sizeBytes: Int64
    let language: String?
    let lines: [Line]
    let events: [Event]
    let keyframes: [Double]

    var id: URL { url }
    var transcript: String { lines.map(\.text).joined(separator: " ") }
    var clicks: Int { events.filter { $0.type == "click" }.count }
}

private struct ManifestFile: Decodable {
    let format: String
    let video: String
    let createdAt: String
    let duration: Double?
    let quality: String?
}

private struct TimelineFile: Decodable {
    struct Piece: Decodable { let start: Double; let end: Double; let text: String }
    struct Speech: Decodable { let language: String?; let segments: [Piece] }
    struct Keyframe: Decodable { let t: Double }
    struct Event: Decodable {
        let t: Double
        let type: String
        let button: String?
        let x: Double?
        let y: Double?
        let app: String?
        let name: String?
        let keys: Int?
        let duration: Double?
        let modifiers: [String]?
    }

    let events: [Event]?
    let speech: Speech?
    let keyframes: [Keyframe]?
}

enum RecordingReader {
    static func read(_ bundle: URL) -> Recording? {
        guard let data = try? Data(contentsOf: bundle.appendingPathComponent("manifest.json")),
              let manifest = try? JSONDecoder().decode(ManifestFile.self, from: data),
              manifest.format == "watch-bundle" else { return nil }
        let video = Handoff.videoURL(in: bundle)
        let timeline = (try? Data(contentsOf: bundle.appendingPathComponent("timeline.json"))).flatMap { try? JSONDecoder().decode(TimelineFile.self, from: $0) }
        let size = (try? FileManager.default.attributesOfItem(atPath: video.path)[.size] as? NSNumber)?.int64Value ?? 0
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let created = iso.date(from: manifest.createdAt) ?? ISO8601DateFormatter().date(from: manifest.createdAt) ?? Date.distantPast
        return Recording(
            url: bundle,
            videoURL: video,
            createdAt: created,
            duration: manifest.duration ?? 0,
            quality: manifest.quality.flatMap(Quality.init(rawValue:)),
            sizeBytes: size,
            language: timeline?.speech?.language,
            lines: (timeline?.speech?.segments ?? []).map { Recording.Line(start: $0.start, end: $0.end, text: $0.text) },
            events: (timeline?.events ?? []).map(describe),
            keyframes: (timeline?.keyframes ?? []).map(\.t)
        )
    }

    private static func describe(_ e: TimelineFile.Event) -> Recording.Event {
        let place = e.app.map { L.t(" in \($0)", " dans \($0)", " · \($0)") } ?? ""
        switch e.type {
        case "click":
            let x = Int(((e.x ?? 0) * 100).rounded()), y = Int(((e.y ?? 0) * 100).rounded())
            return .init(t: e.t, type: e.type, text: L.t("Click at \(x)%, \(y)%", "Clic à \(x) %, \(y) %", "클릭 (\(x)%, \(y)%)") + place, symbol: "cursorarrow.click")
        case "typing":
            return .init(t: e.t, type: e.type, text: L.t("Typed \(e.keys ?? 0) keys", "Frappe de \(e.keys ?? 0) touches", "키 \(e.keys ?? 0)번 입력") + place, symbol: "keyboard")
        case "shortcut":
            return .init(t: e.t, type: e.type, text: L.t("Shortcut ", "Raccourci ", "단축키 ") + (e.modifiers ?? []).joined(separator: "+") + place, symbol: "command")
        case "app":
            return .init(t: e.t, type: e.type, text: L.t("Switched to ", "Passage à ", "앱 전환: ") + (e.name ?? "?"), symbol: "macwindow")
        default:
            return .init(t: e.t, type: e.type, text: e.type, symbol: "circle")
        }
    }
}

/// All recordings in the recordings folder, newest first.
@MainActor @Observable
final class RecordingLibrary {
    private(set) var recordings: [Recording] = []
    var folder: URL = Settings.recordingsFolder

    func reload() {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        recordings = urls.filter { $0.pathExtension == "watch" }.compactMap(RecordingReader.read).sorted { $0.createdAt > $1.createdAt }
    }

    /// Moves a recording to the Trash (it can be put back from there).
    func moveToTrash(_ recording: Recording) {
        NSWorkspace.shared.recycle([recording.url]) { _, _ in
            Task { @MainActor in self.reload() }
        }
    }

    var totalBytes: Int64 { recordings.reduce(0) { $0 + $1.sizeBytes } }

    /// Average megabytes per minute of this preset's recordings, measured on this Mac.
    func measuredMBPerMinute(_ quality: Quality) -> Double? {
        let samples = recordings.filter { $0.quality == quality && $0.duration >= 3 }
        let seconds = samples.reduce(0) { $0 + $1.duration }
        guard seconds > 0 else { return nil }
        let bytes = samples.reduce(Int64(0)) { $0 + $1.sizeBytes }
        return Double(bytes) / 1_000_000 / (seconds / 60)
    }
}

/// Still frames for cards and the keyframe strip, cached in memory.
@MainActor
final class Thumbnails {
    static let shared = Thumbnails()
    private var cache: [String: NSImage] = [:]

    func cachedImage(key: String) -> NSImage? { cache[key] }

    func image(for video: URL, at seconds: Double, maxWidth: CGFloat = 480) async -> NSImage? {
        let key = "\(video.path)#\(Int(seconds * 10))#\(Int(maxWidth))"
        if let hit = cache[key] { return hit }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: video))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxWidth, height: maxWidth)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        guard let (cgImage, _) = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)) else { return nil }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        cache[key] = image
        return image
    }
}
