import AppKit
import SwiftUI

/// Every option in one place, each with a short explanation of what it changes.
struct SettingsView: View {
    let onboarding: OnboardingController
    let library: RecordingLibrary
    @State private var quality = Settings.quality
    @State private var microphone = Settings.recordMicrophone
    @State private var maxMinutes = Settings.maxMinutes
    @State private var language = Settings.appLanguage
    @State private var showInDock = Settings.showInDock

    var body: some View {
        let model = onboarding.model
        MaybeScroll {
            VStack(alignment: .leading, spacing: 26) {
                Text(L.t("Settings", "Réglages", "설정")).font(Theme.headline(32))
                Section(title: L.t("Language", "Langue", "언어"), note: nil) {
                    Picker(L.t("Interface language", "Langue de l'interface", "인터페이스 언어"), selection: Binding(get: { language }, set: { language = $0; Settings.appLanguage = $0 })) {
                        ForEach(AppLanguage.allCases) { Text($0.name).tag($0) }
                    }.pickerStyle(.segmented)
                }
                Section(title: L.t("App", "App", "앱"), note: L.t("Off: WatchRecorder stays in the menu bar only.", "Désactivé : WatchRecorder reste seulement dans la barre des menus.", "끄면 WatchRecorder는 메뉴 막대에만 있어요.")) {
                    Toggle(L.t("Show in the Dock", "Afficher dans le Dock", "Dock에 표시"), isOn: Binding(get: { showInDock }, set: { on in
                        showInDock = on
                        Settings.showInDock = on
                        DockIcon.apply()
                        NSApp.activate()
                    }))
                }
                Section(title: L.t("Recording quality", "Qualité d'enregistrement", "녹화 품질"),
                        note: L.t("Image tokens are computed with Anthropic's image formula for a 1-minute recording; file sizes are measured on your own recordings.",
                                  "Les tokens image sont calculés avec la formule d'Anthropic pour 1 min d'enregistrement ; les tailles de fichier sont mesurées sur tes propres enregistrements.", "이미지 토큰은 1분 녹화 기준으로 Anthropic의 이미지 공식으로 계산하고, 파일 크기는 내 녹화에서 측정해요.")) {
                    QualityCards(selection: Binding(get: { quality }, set: { quality = $0; Settings.quality = $0 }), library: library)
                }
                Section(title: L.t("Recording", "Enregistrement", "녹화"), note: nil) {
                    Toggle(L.t("Record my voice", "Enregistrer ma voix", "내 목소리 녹음"), isOn: Binding(get: { microphone }, set: { microphone = $0; Settings.recordMicrophone = $0 }))
                    Stepper(value: Binding(get: { maxMinutes }, set: { maxMinutes = $0; Settings.defaults.set($0, forKey: "MaxMinutes") }), in: 1...120, step: 1) {
                        Text(L.t("Stop by itself after \(Int(maxMinutes)) min", "S'arrête tout seul après \(Int(maxMinutes)) min", "\(Int(maxMinutes))분 후 자동으로 멈춤"))
                    }
                    HStack {
                        Text(L.t("Shortcut", "Raccourci", "단축키"))
                        Spacer()
                        KeyCaps(display: model.shortcut).scaleEffect(0.7)
                        Button(L.t("Change…", "Changer…", "변경…")) { onboarding.show(at: .shortcut) }
                    }
                }
                Section(title: L.t("Your AI apps", "Tes apps d'IA", "내 AI 앱"), note: nil) {
                    ConnectPanel(controller: onboarding, model: model)
                }
                Section(title: L.t("Permissions", "Permissions", "권한"), note: L.t("Granted in System Settings. WatchRecorder only asks when you click.", "Accordées dans les Réglages Système. WatchRecorder ne demande que quand tu cliques.", "시스템 설정에서 허용해요. WatchRecorder는 클릭할 때만 물어봐요.")) {
                    ForEach(Permission.allCases) { permission in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(permission.title).font(.system(size: 13, weight: .medium))
                                Text(permission.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if model.isGranted(permission) {
                                StatusChip(ok: true, text: L.t("Allowed", "Autorisé", "허용됨"))
                            } else {
                                Button(L.t("Allow", "Autoriser", "허용")) { Task { await permission.request() } }
                            }
                        }
                    }
                }
                Section(title: L.t("Storage", "Stockage", "저장 공간"), note: nil) {
                    HStack {
                        Text(Settings.recordingsFolder.path).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(Format.bytes(library.totalBytes)).foregroundStyle(.secondary)
                        Button(L.t("Show in Finder", "Afficher", "Finder에서 보기")) { NSWorkspace.shared.open(Settings.recordingsFolder) }
                    }
                }
            }
            .padding(.horizontal, 36).padding(.top, 44).padding(.bottom, 36)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .onAppear { model.refreshPermissions() }
    }
}

private struct Section<Content: View>: View {
    let title: String
    let note: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 15, weight: .semibold))
            if let note { Text(note).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            VStack(alignment: .leading, spacing: 10) { content }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.line))
        }
    }
}
