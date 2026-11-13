import SwiftUI
import AppKit
import Observation

/// Liquid Glass tasarım tokenları (spesifikasyon › "Tasarım tokenları").
/// Tema değişince yalnızca token değerleri değişir; vurgu rengi tek yerden (`accent`) gelir.
enum Theme {
    // MARK: Vurgu

    /// `Appearance` gözlemlendiği için body içinde okununca vurgu değişikliği view'ları yeniden çizer.
    static var accent: Color { Appearance.shared.accent.color }

    /// Vurgu üzerindeki yazı: parlaklık > 0,18 ise koyu, değilse beyaz.
    static var onAccent: Color {
        Appearance.shared.accent.luminance > 0.18 ? Color(hex: 0x1D1D1F) : .white
    }

    /// Birincil butonun dış parlaması: koyu temada %45, açıkta %35.
    static var accentGlow: Color {
        let base = Appearance.shared.accent.nsColor
        return Color(light: base.withAlphaComponent(0.35), dark: base.withAlphaComponent(0.45))
    }

    /// Açık zeminde vurgu renkli yazı (kontrast için ×0,62 koyulaştırılmış); koyuda hafif açılmış vurgu.
    static var accentInk: Color {
        let base = Appearance.shared.accent.nsColor
        let darkened = NSColor(
            srgbRed: base.redComponent * 0.62, green: base.greenComponent * 0.62,
            blue: base.blueComponent * 0.62, alpha: 1
        )
        return Color(light: darkened, dark: base.blended(withFraction: 0.2, of: .white) ?? base)
    }

    // MARK: Yazı

    static let textPrimary = Color(light: NSColor(hex: 0x1D1D1F), dark: .white)
    static let textSecondary = Color(light: NSColor(hex: 0x5D5B66), dark: .white.withAlphaComponent(0.74))
    static let textTertiary = Color(light: NSColor(hex: 0x5D5B66).withAlphaComponent(0.8), dark: .white.withAlphaComponent(0.6))

    // MARK: Durum

    static let success = Color(light: NSColor(hex: 0x1F9D6B), dark: NSColor(hex: 0x34D399))
    static let successText = Color(light: NSColor(hex: 0x1F9D6B), dark: NSColor(hex: 0x7EE0B5))
    static let warning = Color(light: NSColor(hex: 0xB7791F), dark: NSColor(hex: 0xF5B82E))
    static let warningText = Color(light: NSColor(hex: 0xB7791F), dark: NSColor(hex: 0xFFD27A))
    static let critical = Color(light: NSColor(hex: 0xC81E5B), dark: NSColor(hex: 0xFF3D7F))
    static let criticalText = Color(light: NSColor(hex: 0xC81E5B), dark: NSColor(hex: 0xFF9CBC))
    static let info = Color(hex: 0x1FB6C9)

    // MARK: Cam yüzeyler

    /// `window`: ana pencere, Başlangıç, Ayarlar.
    static let windowTint = Color(
        light: .white.withAlphaComponent(0.60),
        dark: NSColor(hex: 0x1C1A22).withAlphaComponent(0.60)
    )
    /// "Şeffaflığı azalt" açıkken camın yerine düz dolgu.
    static let windowSolid = Color(light: NSColor(hex: 0xF4F3F8), dark: NSColor(hex: 0x232129))
    static let windowEdge = Color(light: .black.withAlphaComponent(0.07), dark: .white.withAlphaComponent(0.10))
    static let windowHighlight = Color(light: .white.withAlphaComponent(0.95), dark: .white.withAlphaComponent(0.28))

    /// `glass`: kart, satır, ikon buton, input.
    static let glassFill = Color(light: .white.withAlphaComponent(0.62), dark: .white.withAlphaComponent(0.07))
    static let glassEdge = Color(light: .black.withAlphaComponent(0.06), dark: .white.withAlphaComponent(0.08))
    static let glassHighlight = Color(light: .white.withAlphaComponent(0.95), dark: .white.withAlphaComponent(0.22))

    /// `selected`: seçili satır / seçenek zemini (kenarı vurgu halkası).
    static let selectedFill = Color(light: .white, dark: .white.withAlphaComponent(0.13))
    /// Nötr seçili segment ("Büyük", "Görüntü üzerinde").
    static let neutralSelected = Color(light: .white, dark: .white.withAlphaComponent(0.18))
    /// Cam üstünde biraz daha dolu buton ("Katıl", "Tamam").
    static let raisedFill = Color(light: .white.withAlphaComponent(0.85), dark: .white.withAlphaComponent(0.14))

    static let divider = Color(light: NSColor(hex: 0x1D1D1F).withAlphaComponent(0.08), dark: .white.withAlphaComponent(0.08))
    static let track = Color(light: .black.withAlphaComponent(0.10), dark: .white.withAlphaComponent(0.14))
    static let switchOff = Color(light: .black.withAlphaComponent(0.14), dark: .white.withAlphaComponent(0.20))
    static let kbd = Color(light: .black.withAlphaComponent(0.08), dark: .white.withAlphaComponent(0.16))
    static let dashedEdge = Color(light: .black.withAlphaComponent(0.18), dark: .white.withAlphaComponent(0.26))
    static let shadow = Color(light: NSColor(hex: 0x281E50).withAlphaComponent(0.18), dark: .black.withAlphaComponent(0.5))

    // MARK: Köşe, boyut

    /// Pencere kenarı macOS'un kendi köşe yarıçapıyla aynı olmalı (macOS 26+: 16 pt): içerik daha büyük
    /// yarıçapla kırpılırsa köşede pencerenin koyu zemini görünür.
    @MainActor static var windowRadius: CGFloat { systemWindowRadius }
    @MainActor static var videoWindowRadius: CGFloat { systemWindowRadius }

    /// Bizim pencerelerle aynı biçimdeki bir pencereden okunur; okunamazsa macOS 14/15'in değeri.
    @MainActor static let systemWindowRadius: CGFloat = {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: true)
        let key = "_cornerRadius"
        guard window.responds(to: NSSelectorFromString(key)), let value = window.value(forKey: key) as? NSNumber,
              value.doubleValue > 0, value.doubleValue < 40 else { return 10 }
        return CGFloat(value.doubleValue)
    }()
    static let panelRadius: CGFloat = 26
    static let cardRadius: CGFloat = 22
    static let rowRadius: CGFloat = 16
    static let controlHeight: CGFloat = 44
    static let panelWidth: CGFloat = 384

    /// Animasyon varsayılanı (spesifikasyon › Bileşenler).
    static let spring = Animation.spring(response: 0.35, dampingFraction: 0.85)
}

/// Video üzerindeki katmanlar her temada koyu: bu değerler temadan bağımsız.
enum Overlay {
    static let text = Color.white
    static let secondary = Color.white.opacity(0.75)
    static let tertiary = Color.white.opacity(0.62)
    static let glass = Color.white.opacity(0.08)
    static let raised = Color.white.opacity(0.14)
    static let selected = Color.white.opacity(0.13)
    static let track = Color.white.opacity(0.16)
    static let buffered = Color.white.opacity(0.24)
    static let tint = Color(red: 28 / 255, green: 26 / 255, blue: 34 / 255).opacity(0.58)
    static let solid = Color(red: 34 / 255, green: 32 / 255, blue: 40 / 255)
}

// MARK: - Görünüm tercihleri

/// Tema ve vurgu rengi. `@Observable` olduğundan Theme okuyan her view değişikliği izler.
@Observable
final class Appearance {
    static let shared = Appearance()

    var theme: AppTheme {
        didSet {
            UserDefaults.standard.set(theme.rawValue, forKey: "appTheme")
            apply()
        }
    }

    var accent: AccentChoice {
        didSet { UserDefaults.standard.set(accent.rawValue, forKey: "accent") }
    }

    private init() {
        theme = UserDefaults.standard.string(forKey: "appTheme").flatMap(AppTheme.init) ?? .system
        accent = UserDefaults.standard.string(forKey: "accent").flatMap(AccentChoice.init) ?? .orange
    }

    /// Tüm pencerelere uygular; nil = sistemi izle.
    func apply() {
        NSApp?.appearance = switch theme {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

enum AppTheme: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: Self { self }
    var title: String {
        switch self {
        case .system: "Sistem"
        case .light: "Açık"
        case .dark: "Koyu"
        }
    }
}

/// Ayarlar'da sunulan vurgu seçenekleri: #F08A2E, #6D5CFF, #1FB6C9, #FF3D7F.
enum AccentChoice: String, CaseIterable, Identifiable {
    case orange, violet, teal, pink
    var id: Self { self }

    var title: String {
        switch self {
        case .orange: "Turuncu"
        case .violet: "Mor"
        case .teal: "Turkuaz"
        case .pink: "Pembe"
        }
    }

    var hex: UInt32 {
        switch self {
        case .orange: 0xF08A2E
        case .violet: 0x6D5CFF
        case .teal: 0x1FB6C9
        case .pink: 0xFF3D7F
        }
    }

    var nsColor: NSColor { NSColor(hex: hex) }
    var color: Color { Color(nsColor: nsColor) }

    /// WCAG göreli parlaklığı.
    var luminance: CGFloat {
        let color = nsColor
        func linear(_ value: CGFloat) -> CGFloat {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.redComponent) + 0.7152 * linear(color.greenComponent) + 0.0722 * linear(color.blueComponent)
    }
}

// MARK: - Renk yardımcıları

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(nsColor: NSColor(hex: hex).withAlphaComponent(opacity))
    }

    /// Açık/koyu görünüme göre kendiliğinden değişen renk.
    init(light: NSColor, dark: NSColor) {
        self.init(nsColor: NSColor(name: nil) { $0.isDark ? dark : light })
    }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// Kişiye sabit avatar / küçük resim gradyanı (ad ya da hash'ten türetilir).
enum Palette {
    static let gradients: [(UInt32, UInt32)] = [
        (0xFFB067, 0xE0701C), (0x8B7CFF, 0x5440E0), (0x4FD6E5, 0x1592A3),
        (0xFF7BA6, 0xE0306A), (0x7EE0B5, 0x23A774), (0xFFD27A, 0xD9952A),
    ]

    static func gradient(for seed: String) -> LinearGradient {
        var hash: UInt64 = 5381
        for byte in seed.utf8 { hash = (hash &* 33) ^ UInt64(byte) }
        let pair = gradients[Int(hash % UInt64(gradients.count))]
        return LinearGradient(colors: [Color(hex: pair.0), Color(hex: pair.1)], startPoint: .top, endPoint: .bottom)
    }
}
