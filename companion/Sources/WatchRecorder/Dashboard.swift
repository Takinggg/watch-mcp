import AppKit
import AVKit
import SwiftUI

enum DashboardSection: Hashable {
    case recordings, settings
}

@MainActor @Observable
final class DashboardModel {
    var section: DashboardSection = .recordings
    var selected: Recording?
    var search = ""
    let library = RecordingLibrary()
    /// Set by the app: hands a recording to the AI app (prompt, state file, bring the app forward).
    var sendToAI: (Recording) -> Void = { _ in }
    var startRecording: () -> Void = {}
    var openSetup: () -> Void = {}
    /// True while rendering screenshots (`--render-ui`): no live video player.
    var rendering = false
}

/// The main window: a library of recordings with a player, the transcript and what was done.
@MainActor
final class DashboardController {
    let model = DashboardModel()
    private var window: NSWindow?
    private let onboarding: OnboardingController

    init(onboarding: OnboardingController) {
        self.onboarding = onboarding
        // Back from System Settings: show the permissions as they are now.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.window?.isVisible == true else { return }
                self.refreshPermissions()
            }
        }
        NotificationCenter.default.addObserver(forName: .watchRecorderLanguageChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let window = self.window else { return }
                window.contentView = NSHostingView(rootView: DashboardView(model: self.model, onboarding: self.onboarding))
            }
        }
    }

    /// The setup checklist reads the permissions from the setup model, which is otherwise only
    /// filled while the setup window is open.
    func refreshPermissions() {
        onboarding.model.refreshPermissions()
    }

    func show() {
        refreshPermissions()
        model.library.reload()
        Task { await onboarding.refreshClients(install: false) }
        if window == nil { window = makeWindow() }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func reload() {
        model.library.reload()
        if let selected = model.selected { model.selected = model.library.recordings.first { $0.id == selected.id } }
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 720), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.title = "WatchRecorder"
        window.minSize = NSSize(width: 900, height: 560)
        window.contentView = NSHostingView(rootView: DashboardView(model: model, onboarding: onboarding))
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("WatchRecorderDashboard")
        window.center()
        return window
    }
}

struct DashboardView: View {
    let model: DashboardModel
    let onboarding: OnboardingController

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(model: model)
            Rectangle().fill(Theme.line).frame(width: 1)
            Group {
                switch model.section {
                case .recordings:
                    if let recording = model.selected {
                        RecordingDetail(recording: recording, model: model)
                    } else {
                        LibraryView(model: model, onboarding: onboarding)
                    }
                case .settings:
                    SettingsView(onboarding: onboarding, library: model.library)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.canvas)
        }
        .frame(minWidth: 900, minHeight: 560)
    }
}

/// Warm off-white column with navigation, recent recordings and the record button.
private struct Sidebar: View {
    let model: DashboardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 9) {
                AppLogo(size: 26)
                Text("WatchRecorder").font(.system(size: 15, weight: .semibold, design: .serif))
            }.padding(.horizontal, 10).padding(.top, 34).padding(.bottom, 18)
            SidebarItem(title: L.t("Recordings", "Enregistrements", "녹화"), symbol: "film.stack", count: model.library.recordings.count, active: model.section == .recordings && model.selected == nil) {
                model.section = .recordings
                model.selected = nil
            }
            SidebarItem(title: L.t("Settings", "Réglages", "설정"), symbol: "gearshape", count: nil, active: model.section == .settings) { model.section = .settings }
            SidebarItem(title: L.t("Setup guide", "Guide de démarrage", "시작 가이드"), symbol: "sparkles", count: nil, active: false) { model.openSetup() }
            if !model.library.recordings.isEmpty {
                Text(L.t("Recent", "Récents", "최근")).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.top, 18).padding(.bottom, 4)
                ForEach(model.library.recordings.prefix(6)) { recording in
                    Button { model.section = .recordings; model.selected = recording } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(recording.lines.first?.text ?? L.t("Recording without speech", "Enregistrement sans parole", "음성 없는 녹화")).font(.system(size: 12)).lineLimit(1)
                            Text(L.date(recording.createdAt, date: .abbreviated, time: .shortened)).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(model.selected?.id == recording.id ? Theme.subtle : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
            Spacer()
            Button(action: model.startRecording) {
                Label(L.t("Record", "Enregistrer", "녹화"), systemImage: "record.circle").frame(maxWidth: .infinity)
            }.buttonStyle(PrimaryButtonStyle(tint: Theme.record))
            HStack(spacing: 4) {
                Text(L.t("or", "ou", "또는")).foregroundStyle(.secondary)
                Text(Settings.hotKey.display).fontWeight(.semibold)
                Text(L.t("from anywhere", "depuis n'importe où", "어디서나 가능")).foregroundStyle(.secondary)
            }.font(.system(size: 11)).frame(maxWidth: .infinity).padding(.top, 4)
        }
        .padding(.horizontal, 12).padding(.bottom, 16)
        .frame(width: 236)
        .background(Theme.sidebar)
    }
}

private struct SidebarItem: View {
    let title: String
    let symbol: String
    let count: Int?
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol).frame(width: 18).foregroundStyle(active ? Theme.accent : .secondary)
                Text(title)
                Spacer()
                if let count, count > 0 { Text("\(count)").foregroundStyle(.secondary).font(.system(size: 11)) }
            }
            .font(.system(size: 13, weight: active ? .semibold : .regular))
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(active ? Theme.subtle.opacity(1.6) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

// MARK: - Library

private struct LibraryView: View {
    let model: DashboardModel
    let onboarding: OnboardingController
    @Environment(\.renderingSnapshot) private var snapshot

    var body: some View {
        let shown = filtered()
        MaybeScroll {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(greeting()).font(Theme.headline(34))
                    Text(model.library.recordings.isEmpty
                         ? L.t("Show your screen while you talk; your AI watches it.", "Montre ton écran en parlant, ton IA regarde.", "말하면서 화면을 보여 주세요. AI가 지켜봐요.")
                         : model.library.recordings.count == 1
                         ? L.t("1 recording, \(Format.bytes(model.library.totalBytes)), on this Mac.", "1 enregistrement, \(Format.bytes(model.library.totalBytes)), sur ce Mac.", "녹화 1개, \(Format.bytes(model.library.totalBytes)), 이 Mac에 있어요.")
                         : L.t("\(model.library.recordings.count) recordings, \(Format.bytes(model.library.totalBytes)), all on this Mac.", "\(model.library.recordings.count) enregistrements, \(Format.bytes(model.library.totalBytes)), tous sur ce Mac.", "녹화 \(model.library.recordings.count)개, \(Format.bytes(model.library.totalBytes)), 모두 이 Mac에 있어요."))
                        .foregroundStyle(.secondary)
                }
                SetupChecklist(onboarding: onboarding, library: model.library)
                if !model.library.recordings.isEmpty { SearchField(text: Binding(get: { model.search }, set: { model.search = $0 })) }
                if model.library.recordings.isEmpty {
                    EmptyLibrary()
                } else if shown.isEmpty {
                    Text(L.t("Nothing said matches this search.", "Rien de ce qui a été dit ne correspond.", "검색과 일치하는 말이 없어요.")).foregroundStyle(.secondary)
                } else {
                    ForEach(groups(shown), id: \.title) { group in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(group.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230, maximum: 320), spacing: 18)], spacing: 18) {
                                ForEach(group.items) { recording in
                                    RecordingCard(recording: recording, rendering: model.rendering).onTapGesture { model.selected = recording }
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 36).padding(.top, 44).padding(.bottom, 36)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private func greeting() -> String {
        let hour = Calendar.current.component(.hour, from: Date())
        // Screenshots (render mode) stay anonymous.
        let first = snapshot ? nil : NSFullUserName().split(separator: " ").first.map(String.init)
        let hello = hour < 12 ? L.t("Good morning", "Bonjour", "좋은 아침이에요") : hour < 18 ? L.t("Good afternoon", "Bon après-midi", "안녕하세요") : L.t("Good evening", "Bonsoir", "좋은 저녁이에요")
        return first.map { "\(hello), \($0)" } ?? hello
    }

    private func filtered() -> [Recording] {
        let query = model.search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return model.library.recordings }
        return model.library.recordings.filter { $0.transcript.lowercased().contains(query) }
    }

    private func groups(_ recordings: [Recording]) -> [(title: String, items: [Recording])] {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = L.locale
        formatter.dateStyle = .full
        var result: [(title: String, items: [Recording])] = []
        for recording in recordings {
            let title = calendar.isDateInToday(recording.createdAt) ? L.t("Today", "Aujourd'hui", "오늘")
                : calendar.isDateInYesterday(recording.createdAt) ? L.t("Yesterday", "Hier", "어제")
                : formatter.string(from: recording.createdAt)
            if result.last?.title == title { result[result.count - 1].items.append(recording) } else { result.append((title, [recording])) }
        }
        return result
    }
}

/// A large rounded search box, like the composers of AI apps.
private struct SearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(L.t("Search what was said in your recordings", "Chercher dans ce qui a été dit", "녹화에서 한 말 검색"), text: $text).textFieldStyle(.plain).font(.system(size: 14))
        }
        .padding(.horizontal, 16).frame(height: 44)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.line))
    }
}

/// "Get started, 3 of 5": what is left to set up, each line opening the matching setup step.
private struct SetupChecklist: View {
    let onboarding: OnboardingController
    let library: RecordingLibrary

    var body: some View {
        let items = checklist()
        let done = items.filter(\.done).count
        if done < items.count {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Label(L.t("Get started", "Bien démarrer", "시작하기"), systemImage: "sparkles").font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Text(L.t("\(done) of \(items.count)", "\(done) sur \(items.count)", "\(items.count)개 중 \(done)개")).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 3).background(Theme.subtle, in: Capsule())
                }.padding(16)
                ForEach(items, id: \.title) { item in
                    Divider().overlay(Theme.line)
                    Button { onboarding.show(at: item.step) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: item.done ? "checkmark.circle.fill" : "circle").foregroundStyle(item.done ? Theme.accent : .secondary).font(.system(size: 16))
                            Text(item.title).strikethrough(item.done).foregroundStyle(item.done ? .secondary : .primary).font(.system(size: 13))
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary).font(.system(size: 11, weight: .semibold))
                        }.padding(.horizontal, 16).padding(.vertical, 11).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.line))
            .frame(maxWidth: 640)
        }
    }

    private func checklist() -> [(title: String, done: Bool, step: OnboardingStep)] {
        let model = onboarding.model
        return [
            (L.t("Allow screen recording", "Autoriser l'enregistrement de l'écran", "화면 녹화 허용"), model.isGranted(.screen), .screen),
            (L.t("Allow the microphone", "Autoriser le micro", "마이크 허용"), model.isGranted(.microphone), .microphone),
            (L.t("Choose the recording quality", "Choisir la qualité d'enregistrement", "녹화 품질 선택"), Settings.defaults.object(forKey: "Quality") != nil || Settings.setupFinished, .quality),
            (L.t("Connect your AI apps", "Brancher tes apps d'IA", "AI 앱 연결"), model.clients.contains { $0.action == "ok" }, .connect),
            (L.t("Make a first recording", "Faire un premier enregistrement", "첫 녹화 해 보기"), !library.recordings.isEmpty, .tryIt),
        ]
    }
}

private struct EmptyLibrary: View {
    var body: some View {
        VStack(spacing: 16) {
            MockRecordingWindow()
            Text(L.t("No recording yet", "Pas encore d'enregistrement", "아직 녹화가 없어요")).font(Theme.headline(22))
            Text(L.t("Press \(Settings.hotKey.display), show something while you talk, press it again.", "Appuie sur \(Settings.hotKey.display), montre quelque chose en parlant, rappuie.", "\(Settings.hotKey.display)를 누르고 말하면서 무언가를 보여 준 뒤 다시 누르세요."))
                .foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity).padding(.top, 30)
    }
}

/// A still frame of a recording, loaded once and cached.
struct Thumbnail: View {
    let video: URL
    let seconds: Double
    var maxWidth: CGFloat = 480
    @State private var image: NSImage?

    init(video: URL, seconds: Double, maxWidth: CGFloat = 480) {
        self.video = video
        self.seconds = seconds
        self.maxWidth = maxWidth
        _image = State(initialValue: Thumbnails.shared.cached(for: video, at: seconds, maxWidth: maxWidth))
    }

    var body: some View {
        ZStack {
            Rectangle().fill(Theme.accentDeep.opacity(0.85))
            if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fill) } else { ProgressView().controlSize(.small) }
        }
        .clipped()
        .task(id: "\(video.path)#\(seconds)") {
            if image == nil { image = await Thumbnails.shared.image(for: video, at: seconds, maxWidth: maxWidth) }
        }
    }
}

private struct RecordingCard: View {
    let recording: Recording
    let rendering: Bool
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Thumbnail(video: recording.videoURL, seconds: recording.posterTime)
                .aspectRatio(16 / 10, contentMode: .fit)
                .overlay(alignment: .bottomTrailing) {
                    Text(Format.duration(recording.duration)).font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .padding(.horizontal, 7).padding(.vertical, 3).background(.black.opacity(0.65), in: Capsule()).foregroundStyle(.white).padding(8)
                }
            VStack(alignment: .leading, spacing: 5) {
                Text(recording.lines.first?.text ?? L.t("Recording without speech", "Enregistrement sans parole", "음성 없는 녹화"))
                    .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    .foregroundStyle(recording.lines.isEmpty ? .secondary : .primary)
                Text(recording.lines.count > 1 ? recording.lines[1...].map(\.text).joined(separator: " ") : " ")
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 6) {
                    Text(L.date(recording.createdAt, date: .omitted, time: .shortened)).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    if recording.clicks > 0 { Chip(text: L.t("\(recording.clicks) clicks", "\(recording.clicks) clics", "클릭 \(recording.clicks)번"), symbol: "cursorarrow.click") }
                    if let quality = recording.quality { Chip(text: quality.title, symbol: "slider.horizontal.3") }
                    Spacer(minLength: 0)
                }.padding(.top, 2)
            }.padding(12)
        }
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(hovering ? Theme.accent : Theme.line, lineWidth: hovering ? 2 : 1))
        .shadow(color: .black.opacity(hovering ? 0.12 : 0.05), radius: hovering ? 10 : 4, y: 2)
        .onHover { hovering = $0 }
        .contentShape(Rectangle())
    }
}

struct Chip: View {
    let text: String
    let symbol: String

    var body: some View {
        Label(text, systemImage: symbol).font(.system(size: 10, weight: .medium)).lineLimit(1).fixedSize()
            .padding(.horizontal, 7).padding(.vertical, 3).background(Theme.subtle, in: Capsule())
    }
}

extension Recording {
    /// A representative frame for the card: the second keyframe when there is one.
    var posterTime: Double {
        keyframes.count > 1 ? keyframes[1] : min(1, duration / 2)
    }
}

extension Thumbnails {
    func cached(for video: URL, at seconds: Double, maxWidth: CGFloat) -> NSImage? {
        cachedImage(key: "\(video.path)#\(Int(seconds * 10))#\(Int(maxWidth))")
    }
}
