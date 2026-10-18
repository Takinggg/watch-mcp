import AppKit
import SwiftUI

/// Shared look: the logo's indigo, serif headlines, capsule buttons, and solid surfaces (no
/// translucent materials) in a warm off-white for light mode and soft graphite for dark mode.
enum Theme {
    static let accent = Color(red: 0.31, green: 0.27, blue: 0.90)
    static let accentDeep = Color(red: 0.12, green: 0.11, blue: 0.29)
    static let record = Color(red: 0.96, green: 0.25, blue: 0.37)
    /// Main content background.
    static let canvas = adaptive(light: 0xFFFFFF, dark: 0x1E1E20)
    /// Sidebar and onboarding background.
    static let sidebar = adaptive(light: 0xF7F5F2, dark: 0x18181A)
    /// Cards and panels on top of the canvas.
    static let card = adaptive(light: 0xFFFFFF, dark: 0x2A2A2D)
    static let line = adaptive(light: 0xE8E5E0, dark: 0x3A3A3E)
    static let subtle = Color.primary.opacity(0.05)

    /// Serif headlines, except in Korean, where serif fonts look thin and spaced: bold sans-serif instead.
    static func headline(_ size: CGFloat = 30) -> Font {
        L.current == .ko ? .system(size: size, weight: .bold) : .system(size: size, weight: .semibold, design: .serif)
    }

    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}

/// A headline with its last part in the accent color, as in Wispr Flow's "Let's set up Flow".
struct TwoToneTitle: View {
    let plain: String
    let accent: String
    var size: CGFloat = 32

    var body: some View {
        (Text(plain + " ").foregroundColor(.primary) + Text(accent).foregroundColor(Theme.accent))
            .font(Theme.headline(size)).multilineTextAlignment(.center)
            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
    }
}

/// A miniature of the floating pill WatchRecorder shows while recording.
struct MockPill: View {
    var levels: [Double] = (0..<14).map { 0.2 + 0.7 * abs(sin(Double($0) * 0.9)) }

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(Theme.record).frame(width: 9, height: 9)
            HStack(spacing: 2) {
                ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                    Capsule().fill(.white.opacity(0.9)).frame(width: 3, height: 3 + 15 * level)
                }
            }.frame(height: 18)
            Text("0:07").font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(.white)
            Image(systemName: "stop.fill").font(.system(size: 9)).foregroundStyle(.white.opacity(0.8))
        }
        .padding(.horizontal, 14).frame(height: 34)
        .background(Color.black.opacity(0.82), in: Capsule())
    }
}

/// A miniature window being recorded: dashed accent frame, a red dot, the pill below.
struct MockRecordingWindow: View {
    var body: some View {
        VStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.card)
                .frame(width: 260, height: 150)
                .overlay(alignment: .topLeading) {
                    HStack(spacing: 5) { ForEach(0..<3, id: \.self) { _ in Circle().fill(Theme.line).frame(width: 8, height: 8) } }.padding(10)
                }
                .overlay {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach([0.8, 0.55, 0.7, 0.4], id: \.self) { width in Capsule().fill(Theme.line).frame(width: 190 * width, height: 7) }
                    }.offset(y: 8)
                }
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [7, 5])).padding(-6))
                .overlay(alignment: .topTrailing) { Circle().fill(Theme.record).frame(width: 14, height: 14).offset(x: 12, y: -12) }
            MockPill()
        }
        .padding(.vertical, 8)
    }
}

/// The System Settings row the user has to switch on, drawn as they will see it.
struct MockSettingsRow: View {
    let pane: String
    var on: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(pane).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                AppLogo(size: 24)
                Text("WatchRecorder").font(.system(size: 13))
                Spacer()
                Toggle("", isOn: .constant(on)).toggleStyle(.switch).labelsHidden().allowsHitTesting(false)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.line))
        }
        .frame(width: 300)
    }
}

/// The app icon (drawn by Scripts/make-icon.swift), falling back to an SF Symbol in debug builds.
struct AppLogo: View {
    var size: CGFloat = 96

    var body: some View {
        if let icon = NSImage(named: "AppIcon") ?? Bundle.main.image(forResource: "AppIcon") {
            Image(nsImage: icon).resizable().frame(width: size, height: size)
        } else {
            Image(systemName: "eye.circle.fill").resizable().foregroundStyle(Theme.accent).frame(width: size, height: size)
        }
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    var tint: Color = Theme.accent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 22)
            .frame(minWidth: 220, minHeight: 40)
            .background(tint.opacity(configuration.isPressed ? 0.8 : 1), in: Capsule())
            .contentShape(Capsule())
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 16)
            .frame(minHeight: 32)
            .background(Theme.subtle.opacity(configuration.isPressed ? 2 : 1), in: Capsule())
            .contentShape(Capsule())
    }
}

/// A rounded square holding an SF Symbol, used as the illustration of each step.
struct SymbolTile: View {
    let symbol: String
    var tint: Color = Theme.accent

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 40, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: 96, height: 96)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

/// "Allowed" / "Not yet" pill.
struct StatusChip: View {
    let ok: Bool
    let text: String

    var body: some View {
        Label(text, systemImage: ok ? "checkmark.circle.fill" : "circle.dashed")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(ok ? .green : .secondary)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background((ok ? Color.green : Color.secondary).opacity(0.12), in: Capsule())
    }
}

/// A shortcut drawn as keyboard keys, e.g. ⌥ ⇧ R.
struct KeyCaps: View {
    let display: String

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(display.map(String.init).enumerated()), id: \.offset) { _, key in
                Text(key)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .frame(minWidth: 44, minHeight: 44)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.primary.opacity(0.15)))
                    .shadow(color: .black.opacity(0.08), radius: 0, x: 0, y: 2)
            }
        }
    }
}

/// Microphone bars, fed with levels between 0 and 1.
struct LevelBars: View {
    let levels: [Double]
    var tint: Color = Theme.accent

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                Capsule().fill(tint).frame(width: 4, height: 4 + 36 * level)
            }
        }
        .frame(height: 40)
        .animation(.linear(duration: 0.08), value: levels)
    }
}

enum Format {
    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60) : String(format: "%d:%02d", total / 60, total % 60)
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    static func tokens(_ count: Int) -> String {
        count >= 1000 ? String(format: "%.1fk", Double(count) / 1000) : "\(count)"
    }
}

extension EnvironmentValues {
    /// True while `--render-ui` draws screens offscreen, where scroll views do not draw their content.
    @Entry var renderingSnapshot = false
}

/// A vertical ScrollView, except in offscreen snapshots where the content is laid out as is.
struct MaybeScroll<Content: View>: View {
    @Environment(\.renderingSnapshot) private var snapshot
    @ViewBuilder let content: Content

    var body: some View {
        if snapshot {
            content.fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).clipped()
        } else {
            ScrollView { content }
        }
    }
}
