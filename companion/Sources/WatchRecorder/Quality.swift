import Foundation

/// How much detail a recording keeps, and how much of it the AI is shown.
/// The keyframe rules mirror `defaultBudget` in the watch-mcp server (src/watch.ts).
enum Quality: String, CaseIterable, Identifiable {
    case light, balanced, detailed

    var id: String { rawValue }

    /// Longest edge of the recorded video, in pixels.
    var maxLongEdge: Double {
        switch self {
        case .light: 1280
        case .balanced: 1920
        case .detailed: 2560
        }
    }

    var fps: Int32 {
        switch self {
        case .light: 15
        case .balanced, .detailed: 30
        }
    }

    /// One keyframe per this many seconds, by default.
    var secondsPerKeyframe: Double {
        switch self {
        case .light: 6
        case .balanced: 3
        case .detailed: 1.5
        }
    }

    /// Most keyframes sent for one recording (16 per storyboard image).
    var maxKeyframes: Int {
        switch self {
        case .light: 32
        case .balanced: 64
        case .detailed: 128
        }
    }

    var title: String {
        switch self {
        case .light: L.t("Light", "Léger", "가볍게")
        case .balanced: L.t("Balanced", "Équilibré", "균형")
        case .detailed: L.t("Detailed", "Détaillé", "자세히")
        }
    }

    var summary: String {
        switch self {
        case .light: L.t("Quick demos. Small text can be hard to read; the AI zooms in with frame when it needs to.",
                         "Démos rapides. Le petit texte peut être difficile à lire : l'IA zoome avec frame si besoin.", "빠른 데모용. 작은 글씨는 읽기 어려울 수 있지만, 필요하면 AI가 frame으로 확대해요.")
        case .balanced: L.t("Readable text, enough frames to follow what you do.",
                            "Texte lisible, assez d'images pour suivre ce que tu fais.", "글씨가 잘 읽히고, 하는 일을 따라갈 만큼 이미지가 충분해요.")
        case .detailed: L.t("Small text and fast animations. Uses about twice the AI's context of Balanced.",
                            "Petit texte et animations rapides. Utilise environ deux fois plus de contexte de l'IA qu'Équilibré.", "작은 글씨와 빠른 애니메이션용. '균형'보다 AI 컨텍스트를 약 두 배 써요.")
        }
    }

    /// Keyframes sent for a recording of `seconds` (rounded up to whole storyboards of 16).
    func keyframes(forSeconds seconds: Double) -> Int {
        let wanted = Int((seconds / secondsPerKeyframe).rounded(.up))
        let sheets = max(1, Int((Double(wanted) / 16).rounded(.up)))
        return min(maxKeyframes, sheets * 16)
    }

    /// Image tokens for those keyframes: each full storyboard of a 16:10 screen is 1556x1052 px,
    /// that is ceil(1556/28) x ceil(1052/28) = 56 x 38 = 2128 visual tokens (API formula; an upper
    /// bound, since the last storyboard is often smaller).
    func imageTokens(forSeconds seconds: Double) -> Int {
        let sheets = Int((Double(keyframes(forSeconds: seconds)) / 16).rounded(.up))
        return sheets * 2128
    }
}
