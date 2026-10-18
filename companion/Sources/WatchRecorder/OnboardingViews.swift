import SwiftUI

struct OnboardingView: View {
    let controller: OnboardingController
    let model: OnboardingModel

    var body: some View {
        VStack(spacing: 0) {
            StepProgress(current: model.step)
                .padding(.top, 34).padding(.horizontal, 48)
            Group {
                switch model.step {
                case .welcome: WelcomeStep(controller: controller)
                case .screen: ScreenStep(controller: controller, model: model)
                case .microphone: MicrophoneStep(controller: controller, model: model)
                case .shortcut: ShortcutStep(controller: controller, model: model)
                case .quality: QualityStep(controller: controller, model: model)
                case .connect: ConnectStep(controller: controller, model: model)
                case .tryIt: TryStep(controller: controller, model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 48)
            .transition(.opacity)
        }
        .frame(width: 640, height: 620)
        .background(Theme.sidebar)
        .animation(.easeInOut(duration: 0.2), value: model.step)
    }
}

/// Segmented progress bar with a back button, as in mobile onboarding flows.
private struct StepProgress: View {
    let current: OnboardingStep

    var body: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingStep.allCases, id: \.rawValue) { step in
                Capsule()
                    .fill(step.rawValue <= current.rawValue ? Theme.accent : Theme.subtle)
                    .frame(height: 4)
            }
        }
    }
}

/// The frame every step shares: illustration, serif headline, explanation, content, buttons.
private struct StepLayout<Illustration: View, Content: View, Buttons: View>: View {
    let title: String
    var accent: String = ""
    let text: String
    @ViewBuilder let illustration: Illustration
    @ViewBuilder let content: Content
    @ViewBuilder let buttons: Buttons

    var body: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 8)
            illustration
            TwoToneTitle(plain: title, accent: accent)
            Text(text).font(.system(size: 14)).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            content
            Spacer(minLength: 12)
            VStack(spacing: 10) { buttons }.padding(.bottom, 34)
        }
    }
}

private struct BackButton: View {
    let controller: OnboardingController

    var body: some View {
        Button(L.t("Back", "Retour", "뒤로")) { controller.back() }.buttonStyle(.plain).foregroundStyle(.secondary)
    }
}

private struct WelcomeStep: View {
    let controller: OnboardingController

    var body: some View {
        StepLayout(
            title: L.t("Show it.", "Montre-le.", "보여 주세요."),
            accent: L.t("The AI gets it.", "L'IA comprend.", "AI가 이해해요."),
            text: L.t("Record your screen while you explain out loud. Claude or Codex watches it, hears you, and does what you asked. Everything stays on your Mac.",
                      "Enregistre ton écran en expliquant à voix haute. Claude ou Codex regarde, t'entend, et fait ce que tu demandes. Tout reste sur ton Mac.", "말로 설명하면서 화면을 녹화하세요. Claude나 Codex가 보고, 듣고, 요청한 일을 해요. 모든 것은 이 Mac에만 남아요."),
            illustration: { AppLogo(size: 120) },
            content: {
                VStack(alignment: .leading, spacing: 10) {
                    Bullet(symbol: "lock.shield", text: L.t("Local: video and voice never leave your Mac.", "Local : ni la vidéo ni ta voix ne quittent ton Mac.", "로컬: 영상과 음성은 Mac 밖으로 나가지 않아요."))
                    Bullet(symbol: "chevron.left.forwardslash.chevron.right", text: L.t("Open source, MIT license.", "Open source, licence MIT.", "오픈 소스, MIT 라이선스."))
                    Bullet(symbol: "timer", text: L.t("Two minutes to set up, each step tested.", "Deux minutes de réglage, chaque étape testée.", "2분이면 설정 끝, 단계마다 직접 테스트해요."))
                }.padding(.top, 6)
            },
            buttons: { Button(L.t("Set up", "Commencer", "설정 시작")) { controller.next() }.buttonStyle(PrimaryButtonStyle()) }
        )
    }
}

private struct Bullet: View {
    let symbol: String
    let text: String

    var body: some View {
        Label { Text(text).font(.system(size: 13)) } icon: { Image(systemName: symbol).foregroundStyle(Theme.accent).frame(width: 20) }
    }
}

private struct ScreenStep: View {
    let controller: OnboardingController
    let model: OnboardingModel

    var body: some View {
        let ok = model.isGranted(.screen)
        StepLayout(
            title: L.t("Last step:", "Dernière étape :", "마지막 단계:"),
            accent: L.t("your screen", "ton écran", "화면"),
            text: ok ? L.t("Allowed. On to your first recording.", "Autorisé. Place à ton premier enregistrement.", "허용됐어요. 이제 첫 녹화를 해 봐요.")
                : model.screenAsked
                ? L.t("Switch WatchRecorder on in System Settings, then come back. If macOS offers to quit WatchRecorder, either answer works: you will land on your first recording.",
                      "Active WatchRecorder dans les Réglages Système, puis reviens ici. Si macOS propose de quitter WatchRecorder, les deux réponses marchent : tu arriveras sur ton premier enregistrement.",
                      "시스템 설정에서 WatchRecorder를 켠 다음 돌아오세요. macOS가 WatchRecorder를 종료하겠냐고 물으면 어느 쪽을 골라도 괜찮아요. 첫 녹화 화면으로 이어져요.")
                : L.t("WatchRecorder records the screen only while you record, never its own windows. macOS asks for this once, in System Settings.",
                      "WatchRecorder n'enregistre l'écran que pendant un enregistrement, jamais ses propres fenêtres. macOS le demande une seule fois, dans les Réglages Système.",
                      "WatchRecorder는 녹화하는 동안에만 화면을 녹화하고, 자기 창은 절대 녹화하지 않아요. macOS가 시스템 설정에서 한 번만 물어봐요."),
            illustration: {
                MockSettingsRow(pane: L.t("Screen & System Audio Recording", "Enregistrement de l'écran et de l'audio système", "화면 및 시스템 오디오 녹화"), on: ok)
                    .overlay(alignment: .trailing) { if ok { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title).offset(x: 40, y: 10) } }
                    .padding(.vertical, 18)
            },
            content: { EmptyView() },
            buttons: {
                if ok {
                    Button(L.t("Continue", "Continuer", "계속")) { controller.next() }.buttonStyle(PrimaryButtonStyle())
                } else {
                    Button(L.t("Open System Settings", "Ouvrir les Réglages", "시스템 설정 열기")) { controller.requestScreen() }.buttonStyle(PrimaryButtonStyle())
                    if model.screenAsked {
                        // Fallback when the running app does not see the change (older macOS).
                        Button(L.t("It's on but not detected: relaunch", "C'est activé mais pas détecté : relancer", "켰는데 인식이 안 돼요: 다시 시작")) { controller.relaunchAndResume() }
                            .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                BackButton(controller: controller)
            }
        )
    }
}

private struct MicrophoneStep: View {
    let controller: OnboardingController
    let model: OnboardingModel

    var body: some View {
        let ok = model.isGranted(.microphone)
        StepLayout(
            title: L.t("Talk,", "Parle,", "말해 보세요,"),
            accent: L.t("the AI hears you", "l'IA t'entend", "AI가 들어요"),
            text: ok ? (model.heardVoice ? L.t("Got it. Your voice comes through.", "C'est bon, on t'entend.", "좋아요. 목소리가 잘 들려요.") : L.t("Say something to test it.", "Dis quelque chose pour tester.", "테스트하게 아무 말이나 해 보세요."))
                : L.t("Your voice is recorded with the screen, then transcribed on your Mac.", "Ta voix est enregistrée avec l'écran, puis transcrite sur ton Mac.", "음성은 화면과 함께 녹음되고 Mac에서 받아써요."),
            illustration: {
                if ok {
                    MockPill(levels: Array(model.levels.suffix(14))).scaleEffect(1.6).frame(height: 70)
                        .overlay(alignment: .trailing) { if model.heardVoice { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title).offset(x: 44) } }
                } else {
                    SymbolTile(symbol: "mic.fill")
                }
            },
            content: { EmptyView() },
            buttons: {
                if ok {
                    Button(model.heardVoice ? L.t("Continue", "Continuer", "계속") : L.t("Skip the test", "Passer le test", "테스트 건너뛰기")) { controller.next() }
                        .buttonStyle(PrimaryButtonStyle(tint: model.heardVoice ? Theme.accent : .gray))
                } else {
                    Button(L.t("Allow the microphone", "Autoriser le micro", "마이크 허용")) {
                        Task {
                            await Permission.microphone.request()
                            model.refreshPermissions()
                            if model.isGranted(.microphone) { controller.startMic() }
                        }
                    }.buttonStyle(PrimaryButtonStyle())
                    Button(L.t("Continue without voice", "Continuer sans la voix", "음성 없이 계속")) { controller.next() }.buttonStyle(SecondaryButtonStyle())
                }
                BackButton(controller: controller)
            }
        )
    }
}

private struct ShortcutStep: View {
    let controller: OnboardingController
    let model: OnboardingModel
    private let presets = ["opt+shift+r", "ctrl+opt+r", "ctrl+shift+r"]

    var body: some View {
        StepLayout(
            title: L.t("One shortcut", "Un raccourci", "단축키 하나로"),
            accent: L.t("to start and stop", "pour démarrer et arrêter", "시작하고 멈춰요"),
            text: model.shortcutTested ? L.t("It works. Same keys to start and to stop a recording.", "Ça marche. Mêmes touches pour démarrer et arrêter.", "잘 돼요. 같은 키로 녹화를 시작하고 멈춰요.")
                : L.t("Press it now to test it (nothing is recorded during this step).", "Appuie dessus maintenant pour tester (rien n'est enregistré à cette étape).", "지금 눌러서 테스트해 보세요(이 단계에서는 아무것도 녹화하지 않아요)."),
            illustration: { KeyCaps(display: model.shortcut).overlay(alignment: .topTrailing) { if model.shortcutTested { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title2).offset(x: 14, y: -14) } } },
            content: {
                Picker(L.t("Shortcut", "Raccourci", "단축키"), selection: Binding(get: { presets.first { HotKeySpec.parse($0)?.display == model.shortcut } ?? presets[0] }, set: { controller.applyShortcut($0) })) {
                    ForEach(presets, id: \.self) { Text(HotKeySpec.parse($0)?.display ?? $0).tag($0) }
                }.pickerStyle(.segmented).frame(width: 260)
            },
            buttons: {
                Button(model.shortcutTested ? L.t("Continue", "Continuer", "계속") : L.t("Skip the test", "Passer le test", "테스트 건너뛰기")) { controller.next() }
                    .buttonStyle(PrimaryButtonStyle(tint: model.shortcutTested ? Theme.accent : .gray))
                BackButton(controller: controller)
            }
        )
    }
}

private struct QualityStep: View {
    let controller: OnboardingController
    let model: OnboardingModel

    var body: some View {
        StepLayout(
            title: L.t("How much", "Quel niveau de", "얼마나"),
            accent: L.t("detail?", "détail ?", "자세하게 할까요?"),
            text: L.t("More detail means sharper video and more frames for the AI, which uses more of its context. You can change it any time.",
                      "Plus de détail, c'est une vidéo plus nette et plus d'images pour l'IA, qui consomme plus de son contexte. Modifiable à tout moment.", "자세할수록 영상이 선명하고 AI에 보내는 이미지가 많아져서 AI 컨텍스트를 더 써요. 언제든 바꿀 수 있어요."),
            illustration: { EmptyView() },
            content: { QualityCards(selection: Binding(get: { model.quality }, set: { model.quality = $0; Settings.quality = $0 }), library: model.library) },
            buttons: {
                Button(L.t("Continue", "Continuer", "계속")) { controller.next() }.buttonStyle(PrimaryButtonStyle())
                BackButton(controller: controller)
            }
        )
    }
}

/// The three presets side by side, with what each costs: computed image tokens, measured file size.
struct QualityCards: View {
    @Binding var selection: Quality
    let library: RecordingLibrary

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(Quality.allCases) { quality in
                QualityCard(quality: quality, selected: selection == quality, measured: library.measuredMBPerMinute(quality))
                    .onTapGesture { selection = quality }
            }
        }
    }
}

private struct QualityCard: View {
    let quality: Quality
    let selected: Bool
    let measured: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(quality.title).font(.system(size: 15, weight: .semibold)).lineLimit(1).fixedSize()
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle").foregroundStyle(selected ? Theme.accent : .secondary)
            }
            Text(quality.summary).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            Stat(label: L.t("Video", "Vidéo", "영상"), value: "\(Int(quality.maxLongEdge)) px · \(quality.fps) \(L.t("fps", "i/s", "fps"))")
            Stat(label: L.t("1 min sent to the AI", "1 min envoyée à l'IA", "AI에 보내는 1분"), value: "\(quality.keyframes(forSeconds: 60)) \(L.t("frames", "images", "장"))")
            Stat(label: L.t("Image tokens", "Tokens image", "이미지 토큰"), value: "≤ \(Format.tokens(quality.imageTokens(forSeconds: 60)))")
            Stat(label: L.t("File per min", "Fichier par min", "분당 파일 크기"), value: measured.map { String(format: L.t("%.0f MB measured", "%.0f Mo mesurés", "측정값 %.0f MB"), $0) } ?? L.t("measured after a recording", "mesuré après un enregistrement", "녹화 후 측정해요"))
        }
        .padding(14)
        .frame(width: 170, alignment: .topLeading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(selected ? Theme.accent : Theme.line, lineWidth: selected ? 2 : 1))
        .overlay(alignment: .top) {
            if quality == .balanced {
                Text(L.t("Recommended", "Recommandé", "추천")).font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 3).background(Theme.accent, in: Capsule()).offset(y: -9)
            }
        }
        .contentShape(Rectangle())
    }
}

private struct Stat: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 12, weight: .medium))
        }
    }
}

private struct ConnectStep: View {
    let controller: OnboardingController
    let model: OnboardingModel

    var body: some View {
        StepLayout(
            title: L.t("Connect", "Branche", "AI 앱을"),
            accent: L.t("your AI apps", "tes apps d'IA", "연결하세요"),
            text: L.t("watch-mcp is added to each AI app found on this Mac, so it can watch your recordings. Restart Claude Desktop or Codex afterwards.",
                      "watch-mcp est ajouté à chaque app d'IA trouvée sur ce Mac, pour qu'elle puisse regarder tes enregistrements. Redémarre Claude Desktop ou Codex ensuite.", "이 Mac에서 찾은 AI 앱마다 watch-mcp를 추가해 녹화를 볼 수 있게 해요. 그다음 Claude Desktop이나 Codex를 다시 시작하세요."),
            illustration: { EmptyView() },
            content: { ConnectPanel(controller: controller, model: model) },
            buttons: {
                Button(L.t("Continue", "Continuer", "계속")) { controller.next() }.buttonStyle(PrimaryButtonStyle())
                BackButton(controller: controller)
            }
        )
    }
}

/// AI apps with their connection state, the send-to choice and automatic pasting.
struct ConnectPanel: View {
    let controller: OnboardingController
    let model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(spacing: 0) {
                ForEach(model.clients) { client in
                    HStack {
                        Text(client.label).font(.system(size: 13, weight: .medium))
                        Spacer()
                        StatusChip(ok: client.action == "ok", text: clientState(client.action))
                    }.padding(.vertical, 6)
                }
                if model.clients.isEmpty { Text(model.clientsMessage ?? L.t("Looking for AI apps…", "Recherche des apps d'IA…", "AI 앱을 찾는 중…")).font(.system(size: 12)).foregroundStyle(.secondary) }
            }
            .padding(12).background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.line))
            if model.clients.contains(where: { $0.action == "add" || $0.action == "update" }) {
                Button(model.installing ? L.t("Connecting…", "Branchement…", "연결하는 중…") : L.t("Connect watch-mcp", "Brancher watch-mcp", "watch-mcp 연결")) { Task { await controller.refreshClients(install: true) } }
                    .buttonStyle(SecondaryButtonStyle()).disabled(model.installing)
            }
            Picker(L.t("After a recording, open", "Après un enregistrement, ouvrir", "녹화 후 열 앱"), selection: Binding(get: { model.sendTo }, set: { model.sendTo = $0; Settings.sendTo = $0 })) {
                Text(L.t("The AI app I was using", "L'app d'IA que j'utilisais", "사용하던 AI 앱")).tag("auto")
                Text("Claude").tag("claude")
                Text("ChatGPT / Codex").tag("codex")
                Text(L.t("Nothing (clipboard)", "Rien (presse-papiers)", "없음(클립보드)")).tag("off")
            }
            Toggle(isOn: Binding(get: { model.autoPaste }, set: { on in if on { Delivery.enableAutoPaste() } else { Settings.autoPaste = false }; model.refreshPermissions() })) {
                Text(L.t("Paste automatically (needs Accessibility)", "Coller automatiquement (demande l'Accessibilité)", "자동으로 붙여넣기(손쉬운 사용 필요)")).font(.system(size: 12))
            }
        }
        .frame(width: 420)
    }

    private func clientState(_ action: String) -> String {
        switch action {
        case "ok": L.t("Connected", "Branché", "연결됨")
        case "absent": L.t("Not installed", "Non installé", "설치 안 됨")
        default: L.t("Not connected", "Pas branché", "연결 안 됨")
        }
    }
}

private struct TryStep: View {
    let controller: OnboardingController
    let model: OnboardingModel

    var body: some View {
        StepLayout(
            title: model.tryResult == nil ? L.t("Your first", "Ton premier", "첫") : L.t("It", "Ça", "잘"),
            accent: model.tryResult == nil ? L.t("recording", "enregistrement", "녹화") : L.t("works", "marche", "돼요"),
            text: model.tryResult == nil
                ? L.t("Press \(model.shortcut), show something while you talk, then press \(model.shortcut) again.", "Appuie sur \(model.shortcut), montre quelque chose en parlant, puis rappuie sur \(model.shortcut).", "\(model.shortcut)를 누르고 말하면서 무언가를 보여 준 다음, \(model.shortcut)를 다시 누르세요.")
                : L.t("Your AI app now has it. You will find every recording in the library.", "Ton app d'IA l'a reçu. Tu retrouveras chaque enregistrement dans la bibliothèque.", "AI 앱이 녹화를 받았어요. 모든 녹화는 라이브러리에서 볼 수 있어요."),
            illustration: { if model.tryResult == nil { MockPill().scaleEffect(1.5).frame(height: 64) } else { SymbolTile(symbol: "sparkles") } },
            content: {
                if let result = model.tryResult {
                    Text("« \(result) »").font(.system(size: 14, design: .serif)).italic().multilineTextAlignment(.center).lineLimit(3)
                        .padding(14).frame(maxWidth: 440).background(Theme.subtle, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else {
                    KeyCaps(display: model.shortcut)
                }
            },
            buttons: {
                Button(model.tryResult == nil ? L.t("Skip", "Passer", "건너뛰기") : L.t("Open the library", "Ouvrir la bibliothèque", "라이브러리 열기")) {
                    controller.finish()
                }.buttonStyle(PrimaryButtonStyle(tint: model.tryResult == nil ? .gray : Theme.accent))
                BackButton(controller: controller)
            }
        )
    }
}
