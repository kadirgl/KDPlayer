import SwiftUI
import Observation

/// Altyazı görünümü (ekran 6). Yalnızca bu kullanıcıda geçerli; odadakiler kendi ayarını kullanır.
struct SubtitleStyle: Codable, Equatable {
    enum Size: String, Codable, CaseIterable, Identifiable {
        case small, medium, large, extraLarge
        var id: Self { self }
        var title: String {
            switch self {
            case .small: "Küçük"
            case .medium: "Orta"
            case .large: "Büyük"
            case .extraLarge: "Çok büyük"
            }
        }
        /// 1080 px yüksekliğe göre punto; pencere boyutuyla ölçeklenir.
        var basePoints: CGFloat {
            switch self {
            case .small: 36
            case .medium: 42
            case .large: 48
            case .extraLarge: 58
            }
        }
        /// Gömülü (VLC'nin çizdiği) altyazı için ölçek yüzdesi.
        var vlcScale: Int {
            switch self {
            case .small: 80
            case .medium: 100
            case .large: 120
            case .extraLarge: 145
            }
        }
    }

    enum FontChoice: String, Codable, CaseIterable, Identifiable {
        case system, rounded, serif
        var id: Self { self }
        var title: String {
            switch self {
            case .system: "Sistem"
            case .rounded: "Yuvarlak"
            case .serif: "Serif"
            }
        }
        var design: Font.Design {
            switch self {
            case .system: .default
            case .rounded: .rounded
            case .serif: .serif
            }
        }
    }

    enum Look: String, Codable, CaseIterable, Identifiable {
        case shadow, box, outline
        var id: Self { self }
        var title: String {
            switch self {
            case .shadow: "Gölge"
            case .box: "Kutu"
            case .outline: "Kenar"
            }
        }
        var caption: String {
            switch self {
            case .shadow: "Okunaklı"
            case .box: "Parlak sahneler"
            case .outline: "Klasik"
            }
        }
    }

    enum TextColor: String, Codable, CaseIterable, Identifiable {
        case white, yellow, lightBlue, lightGreen
        var id: Self { self }
        var title: String {
            switch self {
            case .white: "Beyaz"
            case .yellow: "Sarı"
            case .lightBlue: "Açık mavi"
            case .lightGreen: "Açık yeşil"
            }
        }
        var color: Color {
            switch self {
            case .white: .white
            case .yellow: Color(hex: 0xFFE45C)
            case .lightBlue: Color(hex: 0xA9DCFF)
            case .lightGreen: Color(hex: 0xB7F0C4)
            }
        }
    }

    enum Position: String, Codable, CaseIterable, Identifiable {
        case onImage, letterbox
        var id: Self { self }
        var title: String {
            switch self {
            case .onImage: "Görüntü üzerinde"
            case .letterbox: "Siyah bantta"
            }
        }
    }

    var size: Size = .large
    var font: FontChoice = .system
    var look: Look = .shadow
    var color: TextColor = .white
    var boxOpacity: Double = 0.45
    var position: Position = .onImage

    static let `default` = SubtitleStyle()
}

/// Altyazı görünümü tercihlerinin kalıcı deposu.
@Observable
final class SubtitleStyleStore {
    static let shared = SubtitleStyleStore()

    var style: SubtitleStyle {
        didSet {
            if let data = try? JSONEncoder().encode(style) {
                UserDefaults.standard.set(data, forKey: SettingsKey.subtitleStyle)
            }
            UserDefaults.standard.set(style.size.vlcScale, forKey: SettingsKey.embeddedSubtitleScale)
        }
    }

    private init() {
        style = UserDefaults.standard.data(forKey: SettingsKey.subtitleStyle)
            .flatMap { try? JSONDecoder().decode(SubtitleStyle.self, from: $0) } ?? .default
    }
}

// MARK: - Video üzerindeki altyazı

/// Bizim çizdiğimiz altyazı katmanı. İkinci altyazı birincilin üstünde %70 boyutta durur.
struct SubtitleOverlay: View, Equatable {
    let primary: [SubtitleCue]
    let secondary: [SubtitleCue]
    let style: SubtitleStyle
    /// Videonun ekrandaki dikdörtgeni (siyah bantlar hariç).
    let videoRect: CGRect
    let containerSize: CGSize
    /// Kontrol çubuğu görünürken altyazı yukarı kayar.
    let bottomInset: CGFloat

    var body: some View {
        #if DEBUG
        let _ = PerfCounters.subtitleOverlay += 1
        #endif
        let scale = max(0.45, min(videoRect.height, containerSize.height) / 1080)
        let points = style.size.basePoints * scale
        let topCues = primary.filter(\.top)
        let bottomCues = primary.filter { !$0.top }

        ZStack {
            if !topCues.isEmpty {
                VStack(spacing: 4) {
                    ForEach(topCues) { cue in SubtitleLine(text: cue.text, style: style, points: points) }
                }
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, max(videoRect.minY, 0) + 40 * scale)
            }
            VStack(spacing: 6) {
                ForEach(secondary) { cue in
                    SubtitleLine(text: cue.text, style: style, points: points * 0.7, secondary: true)
                }
                ForEach(bottomCues) { cue in SubtitleLine(text: cue.text, style: style, points: points) }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, bottomPadding(scale: scale))
            .animation(Theme.spring, value: bottomInset)
        }
        .padding(.horizontal, max(24, videoRect.width * 0.08))
        .frame(width: containerSize.width, height: containerSize.height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func bottomPadding(scale: CGFloat) -> CGFloat {
        let videoBottom = containerSize.height - videoRect.maxY
        let base: CGFloat
        if style.position == .letterbox, videoBottom > 60 {
            base = max(12, videoBottom / 2 - 20)
        } else {
            base = max(0, videoBottom) + 56 * scale
        }
        return max(base, bottomInset)
    }
}

struct SubtitleLine: View {
    let text: String
    let style: SubtitleStyle
    let points: CGFloat
    var secondary = false

    var body: some View {
        let font = Font.system(size: points, weight: .semibold, design: style.font.design)
        let color = secondary ? Color.white.opacity(0.78) : style.color.color

        Group {
            switch style.look {
            case .shadow:
                Text(text).font(font).foregroundStyle(color)
                    .shadow(color: .black.opacity(0.8), radius: points * 0.2, y: points * 0.06)
                    .shadow(color: .black.opacity(0.9), radius: 1.5)
            case .box:
                Text(text).font(font).foregroundStyle(color)
                    .padding(.horizontal, points * 0.3)
                    .padding(.vertical, points * 0.06)
                    .background(RoundedRectangle(cornerRadius: points * 0.16, style: .continuous).fill(.black.opacity(style.boxOpacity)))
            case .outline:
                ZStack {
                    ForEach(0..<8, id: \.self) { index in
                        let angle = Double(index) * .pi / 4
                        Text(text).font(font).foregroundStyle(.black)
                            .offset(x: cos(angle) * max(1.2, points * 0.045), y: sin(angle) * max(1.2, points * 0.045))
                    }
                    Text(text).font(font).foregroundStyle(color)
                }
            }
        }
        .multilineTextAlignment(.center)
        .lineSpacing(points * 0.08)
        .fixedSize(horizontal: false, vertical: true)
    }
}
