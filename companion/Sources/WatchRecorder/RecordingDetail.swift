import AppKit
import AVKit
import SwiftUI

/// Plays a recording and follows its time, so the transcript can highlight the current line.
@MainActor @Observable
final class PlayerModel {
    let player: AVPlayer
    var time: Double = 0
    @ObservationIgnored private var observer: Any?

    init(url: URL) {
        player = AVPlayer(url: url)
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.time = time.seconds }
        }
    }

    func seek(_ seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        time = seconds
    }

    func stop() {
        player.pause()
        if let observer { player.removeTimeObserver(observer) }
        observer = nil
    }
}

struct RecordingDetail: View {
    let recording: Recording
    let model: DashboardModel
    @State private var player: PlayerModel
    @State private var tab = 0
    @State private var confirmTrash = false

    init(recording: Recording, model: DashboardModel) {
        self.recording = recording
        self.model = model
        _player = State(initialValue: PlayerModel(url: recording.videoURL))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            HStack(alignment: .top, spacing: 20) {
                VStack(spacing: 12) {
                    video
                    KeyframeStrip(recording: recording, player: player)
                }.frame(minWidth: 420)
                SidePanel(recording: recording, player: player, tab: $tab).frame(width: 340)
            }
        }
        .padding(.horizontal, 28).padding(.top, 34).padding(.bottom, 24)
        .onDisappear { player.stop() }
        .confirmationDialog(L.t("Move this recording to the Trash?", "Mettre cet enregistrement à la corbeille ?", "이 녹화를 휴지통으로 옮길까요?"), isPresented: $confirmTrash) {
            Button(L.t("Move to Trash", "Mettre à la corbeille", "휴지통으로 이동"), role: .destructive) {
                model.library.moveToTrash(recording)
                model.selected = nil
            }
        } message: {
            Text(L.t("You can put it back from the Trash.", "Tu pourras le récupérer dans la corbeille.", "휴지통에서 되돌릴 수 있어요."))
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Button { model.selected = nil } label: { Image(systemName: "chevron.left").font(.system(size: 15, weight: .semibold)) }
                .buttonStyle(.plain).help(L.t("Back to the library", "Retour à la bibliothèque", "라이브러리로 돌아가기"))
            VStack(alignment: .leading, spacing: 4) {
                Text(L.date(recording.createdAt, date: .complete, time: .shortened)).font(Theme.headline(22))
                HStack(spacing: 6) {
                    Chip(text: Format.duration(recording.duration), symbol: "clock")
                    if let quality = recording.quality { Chip(text: quality.title, symbol: "slider.horizontal.3") }
                    Chip(text: Format.bytes(recording.sizeBytes), symbol: "internaldrive")
                    if let language = recording.language { Chip(text: language.uppercased(), symbol: "waveform") }
                }
            }
            Spacer()
            Button(L.t("Send to my AI", "Envoyer à mon IA", "내 AI에 보내기")) { model.sendToAI(recording) }.buttonStyle(PrimaryButtonStyle()).fixedSize()
            Menu {
                Button(L.t("Copy the prompt", "Copier le prompt", "프롬프트 복사")) {
                    Handoff.copyToClipboard(Handoff.prompt(recording: recording.url, duration: recording.duration, transcript: recording.lines.isEmpty ? nil : recording.transcript))
                }
                Button(L.t("Show in Finder", "Afficher dans le Finder", "Finder에서 보기")) { NSWorkspace.shared.activateFileViewerSelecting([recording.url]) }
                Divider()
                Button(L.t("Move to Trash…", "Mettre à la corbeille…", "휴지통으로 이동…"), role: .destructive) { confirmTrash = true }
            } label: { Image(systemName: "ellipsis.circle").font(.system(size: 18)) }
                .menuStyle(.borderlessButton).fixedSize()
        }
    }

    @ViewBuilder private var video: some View {
        Group {
            if model.rendering {
                Thumbnail(video: recording.videoURL, seconds: recording.posterTime, maxWidth: 1200)
                    .overlay { Image(systemName: "play.circle.fill").font(.system(size: 54)).foregroundStyle(.white.opacity(0.9)) }
            } else {
                VideoPlayer(player: player.player)
            }
        }
        .aspectRatio(16 / 10, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Keyframes picked by watch-mcp, as clickable thumbnails.
private struct KeyframeStrip: View {
    let recording: Recording
    let player: PlayerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L.t("Keyframes the AI sees", "Images clés que l'IA voit", "AI가 보는 키프레임")).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(recording.keyframes, id: \.self) { t in
                        Button { player.seek(t) } label: {
                            VStack(spacing: 3) {
                                Thumbnail(video: recording.videoURL, seconds: t, maxWidth: 220).frame(width: 110, height: 69)
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(abs(player.time - t) < 0.25 ? Theme.accent : .clear, lineWidth: 2))
                                Text(Format.duration(t)).font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }.buttonStyle(.plain)
                    }
                    if recording.keyframes.isEmpty { Text(L.t("Not prepared yet", "Pas encore préparées", "아직 준비 안 됨")).font(.system(size: 12)).foregroundStyle(.tertiary) }
                }
            }
        }
    }
}

/// Transcript (what was said) and actions (what was done), both clickable to seek the video.
private struct SidePanel: View {
    let recording: Recording
    let player: PlayerModel
    @Binding var tab: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $tab) {
                Text(L.t("Said", "Dit", "말한 것")).tag(0)
                Text(L.t("Done (\(recording.events.count))", "Fait (\(recording.events.count))", "한 것 (\(recording.events.count))")).tag(1)
            }.pickerStyle(.segmented).labelsHidden()
            ScrollViewReader { proxy in
                MaybeScroll {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        if tab == 0 { transcript } else { actions }
                    }
                }
                .onChange(of: currentLine) { _, line in
                    if let line, tab == 0 { withAnimation { proxy.scrollTo(line, anchor: .center) } }
                }
            }
        }
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.line))
    }

    private var currentLine: Int? {
        recording.lines.lastIndex { $0.start <= player.time + 0.05 }
    }

    @ViewBuilder private var transcript: some View {
        if recording.lines.isEmpty {
            Text(L.t("No speech in this recording.", "Pas de parole dans cet enregistrement.", "이 녹화에는 음성이 없어요.")).font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 8)
        }
        ForEach(Array(recording.lines.enumerated()), id: \.offset) { index, line in
            Row(time: line.start, active: index == currentLine) {
                Text(line.text).font(.system(size: 13, design: .serif)).foregroundStyle(index == currentLine ? .primary : .secondary)
            } action: { player.seek(line.start) }
            .id(index)
        }
    }

    @ViewBuilder private var actions: some View {
        if recording.events.isEmpty {
            Text(L.t("No clicks or app switches were recorded.", "Aucun clic ni changement d'app enregistré.", "기록된 클릭이나 앱 전환이 없어요.")).font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 8)
        }
        ForEach(Array(recording.events.enumerated()), id: \.offset) { _, event in
            Row(time: event.t, active: false) {
                Label(event.text, systemImage: event.symbol).font(.system(size: 12))
            } action: { player.seek(event.t) }
        }
    }
}

private struct Row<Content: View>: View {
    let time: Double
    let active: Bool
    @ViewBuilder let content: Content
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(Format.duration(time)).font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(active ? Theme.accent : .secondary).frame(width: 38, alignment: .leading)
                content.frame(maxWidth: .infinity, alignment: .leading).multilineTextAlignment(.leading)
            }
            .padding(.vertical, 6).padding(.horizontal, 8)
            .background(active ? Theme.accent.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}
