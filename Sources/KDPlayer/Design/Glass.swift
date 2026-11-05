import SwiftUI
import AppKit

// Cam yüzeyler (spesifikasyon › "Cam yüzeyler"). Kenar: üstte 1 px iç parlama + 1 px iç çerçeve.
// "Şeffaflığı azalt" açıkken cam yerine düz dolgu.

enum GlassLevel {
    /// Kart, satır, ikon buton, input.
    case glass
    /// Seçili satır / seçenek: dolgu + vurgu halkası.
    case selected
    /// Cam üstünde dolu buton.
    case raised
}

extension View {
    /// Pencere içi cam (tema ile değişir).
    func glass<S: InsettableShape>(_ level: GlassLevel = .glass, in shape: S) -> some View {
        background(GlassBackground(shape: shape, level: level))
    }

    func glass(_ level: GlassLevel = .glass, radius: CGFloat = Theme.cardRadius) -> some View {
        glass(level, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    /// Video üzerindeki koyu cam (`glassStrong`): kontrol çubuğu, panel, sheet, toast, HUD.
    func overlayGlass<S: InsettableShape>(in shape: S, shadow: Bool = true) -> some View {
        background(OverlayGlassBackground(shape: shape, shadow: shadow))
            .environment(\.colorScheme, .dark)
    }

    func overlayGlass(radius: CGFloat, shadow: Bool = true) -> some View {
        overlayGlass(in: RoundedRectangle(cornerRadius: radius, style: .continuous), shadow: shadow)
    }

    /// Ana pencere camı (Başlangıç, Ayarlar): masaüstünü bulanıklaştırır.
    func windowGlass(radius: CGFloat = Theme.windowRadius) -> some View {
        background(WindowGlassBackground(radius: radius))
    }

    /// Cam kenarı: üstte iç parlama + ince iç çerçeve.
    func glassEdge<S: InsettableShape>(_ shape: S, highlight: Color, edge: Color) -> some View {
        overlay(
            ZStack {
                shape.strokeBorder(edge, lineWidth: 1)
                shape.strokeBorder(
                    LinearGradient(colors: [highlight, .clear], startPoint: .top, endPoint: .init(x: 0.5, y: 0.22)),
                    lineWidth: 1
                )
            }
            .allowsHitTesting(false)
        )
    }
}

private struct GlassBackground<S: InsettableShape>: View {
    let shape: S
    let level: GlassLevel

    var body: some View {
        switch level {
        case .glass:
            shape.fill(Theme.glassFill)
                .glassEdge(shape, highlight: Theme.glassHighlight, edge: Theme.glassEdge)
        case .raised:
            shape.fill(Theme.raisedFill)
                .glassEdge(shape, highlight: Theme.glassHighlight, edge: Theme.glassEdge)
        case .selected:
            shape.fill(Theme.selectedFill)
                .overlay(shape.strokeBorder(Theme.accent, lineWidth: 1.5))
        }
    }
}

private struct OverlayGlassBackground<S: InsettableShape>: View {
    let shape: S
    let shadow: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            if reduceTransparency {
                shape.fill(Overlay.solid)
            } else {
                shape.fill(.ultraThinMaterial)
                shape.fill(Overlay.tint)
            }
        }
        .glassEdge(shape, highlight: .white.opacity(0.30), edge: .white.opacity(0.12))
        .compositingGroup()
        .shadow(color: .black.opacity(shadow ? 0.45 : 0), radius: 20, y: 14)
    }
}

private struct WindowGlassBackground: View {
    let radius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            if reduceTransparency {
                shape.fill(Theme.windowSolid)
            } else {
                VisualEffectBlur(material: .hudWindow, blending: .behindWindow)
                    .clipShape(shape)
                shape.fill(Theme.windowTint)
            }
        }
        .glassEdge(shape, highlight: Theme.windowHighlight, edge: Theme.windowEdge)
    }
}

/// NSVisualEffectView sarmalayıcısı (pencerenin arkasını bulanıklaştırmak için).
struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blending: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
    }
}
