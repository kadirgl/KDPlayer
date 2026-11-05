import SwiftUI

// Bileşenler (spesifikasyon › "Bileşenler"). Her biri tokenlardan beslenir; ekranlar bunların birleşimidir.

// MARK: - Etkileşim

/// Basılınca küçülme, üstüne gelince aydınlanma, pasifken soluklaşma — tüm butonlarda ortak.
private struct Interaction: ViewModifier {
    let isPressed: Bool
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .scaleEffect(isPressed && !reduceMotion ? 0.96 : 1)
            .brightness(hovering && isEnabled ? 0.05 : 0)
            .opacity(isEnabled ? 1 : 0.4)
            .animation(.easeOut(duration: 0.12), value: isPressed)
            .onHover { hovering = $0 }
    }
}

// MARK: - KDButton

/// `KDButton`: primary (vurgu), glass, ghost. Yükseklik 44, tam yuvarlak.
struct KDButtonStyle: ButtonStyle {
    enum Variant { case primary, glass, raised, ghost }

    var variant: Variant = .glass
    var height: CGFloat = Theme.controlHeight
    var fontSize: CGFloat = 13.5
    var fullWidth = false

    func makeBody(configuration: Configuration) -> some View {
        let shape = Capsule(style: .continuous)
        configuration.label
            .font(.system(size: fontSize, weight: .semibold))
            .lineLimit(1)
            // Dar ya da kısa alanda yazı kırpılmasın ("Kap…", "Odayı…").
            .fixedSize(horizontal: !fullWidth, vertical: true)
            .padding(.horizontal, height * 0.4)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: height)
            .foregroundStyle(variant == .primary ? Theme.onAccent : Theme.textPrimary)
            .background {
                switch variant {
                case .primary:
                    shape.fill(Theme.accent)
                        .overlay(shape.strokeBorder(
                            LinearGradient(colors: [.white.opacity(0.45), .clear], startPoint: .top, endPoint: .center),
                            lineWidth: 1
                        ))
                        .shadow(color: Theme.accentGlow, radius: 9, y: 5)
                case .glass:
                    shape.fill(Theme.glassFill)
                        .glassEdge(shape, highlight: Theme.glassHighlight, edge: Theme.glassEdge)
                case .raised:
                    shape.fill(Theme.raisedFill)
                        .glassEdge(shape, highlight: Theme.glassHighlight, edge: Theme.glassEdge)
                case .ghost:
                    Color.clear
                }
            }
            .contentShape(shape)
            .modifier(Interaction(isPressed: configuration.isPressed))
    }
}

extension ButtonStyle where Self == KDButtonStyle {
    static var kdPrimary: KDButtonStyle { KDButtonStyle(variant: .primary) }
    static var kdGlass: KDButtonStyle { KDButtonStyle(variant: .glass) }
    static func kd(_ variant: KDButtonStyle.Variant, height: CGFloat = Theme.controlHeight, fontSize: CGFloat = 13.5, fullWidth: Bool = false) -> KDButtonStyle {
        KDButtonStyle(variant: variant, height: height, fontSize: fontSize, fullWidth: fullWidth)
    }
}

// MARK: - KDIconButton

/// `KDIconButton`: 44 ya da 36 daire; `active` = vurgu iç halkası + parıltı.
struct KDIconButtonStyle: ButtonStyle {
    var size: CGFloat = 44
    var active = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size * 0.38, weight: .semibold))
            .foregroundStyle(Theme.textPrimary)
            .frame(width: size, height: size)
            .background {
                if active {
                    Circle().fill(Theme.raisedFill)
                        .overlay(Circle().strokeBorder(Theme.accent, lineWidth: 1.5))
                        .shadow(color: Theme.accentGlow, radius: 7)
                } else {
                    Circle().fill(Theme.glassFill)
                        .glassEdge(Circle(), highlight: Theme.glassHighlight, edge: Theme.glassEdge)
                }
            }
            .contentShape(Circle())
            .modifier(Interaction(isPressed: configuration.isPressed))
    }
}

extension ButtonStyle where Self == KDIconButtonStyle {
    static func kdIcon(_ size: CGFloat = 44, active: Bool = false) -> KDIconButtonStyle {
        KDIconButtonStyle(size: size, active: active)
    }
}

/// Simge buton kısayolu: her zaman erişilebilirlik etiketiyle.
struct KDIconButton: View {
    let systemName: String
    let label: String
    var size: CGFloat = 44
    var active = false
    let action: () -> Void

    var body: some View {
        Button(action: action) { Image(systemName: systemName) }
            .buttonStyle(.kdIcon(size, active: active))
            .accessibilityLabel(label)
            .help(label)
    }
}

// MARK: - KDPill

/// Cam kapsül (`KDPill`): "EN · TR", "1×", "Değiştir". `expanded` = vurgu halkası (açık popover).
struct KDPillStyle: ButtonStyle {
    var height: CGFloat = 44
    var fontSize: CGFloat = 12.5
    var expanded = false

    func makeBody(configuration: Configuration) -> some View {
        let shape = Capsule(style: .continuous)
        configuration.label
            .font(.system(size: fontSize, weight: .semibold))
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, height >= 40 ? 14 : 12)
            .frame(height: height)
            .foregroundStyle(Theme.textPrimary)
            .background {
                if expanded {
                    shape.fill(Theme.neutralSelected)
                        .overlay(shape.strokeBorder(Theme.accent, lineWidth: 1.5))
                        .shadow(color: Theme.accentGlow, radius: 7)
                } else {
                    shape.fill(Theme.glassFill)
                        .glassEdge(shape, highlight: Theme.glassHighlight, edge: Theme.glassEdge)
                }
            }
            .contentShape(shape)
            .modifier(Interaction(isPressed: configuration.isPressed))
    }
}

extension ButtonStyle where Self == KDPillStyle {
    static func kdPill(height: CGFloat = 44, fontSize: CGFloat = 12.5, expanded: Bool = false) -> KDPillStyle {
        KDPillStyle(height: height, fontSize: fontSize, expanded: expanded)
    }
}

/// Klavye kısayolu rozeti (`kbd`).
struct Kbd: View {
    let text: String
    var onAccent = false

    init(_ text: String, onAccent: Bool = false) {
        self.text = text
        self.onAccent = onAccent
    }

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(onAccent ? Color.black.opacity(0.14) : Theme.kbd)
            )
    }
}

// MARK: - KDSegmented

/// `KDSegmented`: 2–4 seçenek. `accent`: seçili = vurgu dolgu (sekmeler); `neutral`: beyaz %18.
struct KDSegmented<Value: Hashable>: View {
    enum Style { case accent, neutral }

    @Binding var selection: Value
    let options: [(value: Value, title: String)]
    var style: Style = .accent
    var height: CGFloat = 34

    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let isSelected = option.value == selection
                Button {
                    withAnimation(Theme.spring) { selection = option.value }
                } label: {
                    Text(option.title)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .foregroundStyle(isSelected && style == .accent ? Theme.onAccent : Theme.textPrimary.opacity(isSelected ? 1 : 0.85))
                        .frame(maxWidth: .infinity, minHeight: height)
                        .background {
                            if isSelected {
                                selectedBackground.matchedGeometryEffect(id: "seg", in: namespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(4)
        .glass(in: Capsule(style: .continuous))
    }

    @ViewBuilder private var selectedBackground: some View {
        let shape = Capsule(style: .continuous)
        switch style {
        case .accent:
            shape.fill(Theme.accent)
                .overlay(shape.strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.45), .clear], startPoint: .top, endPoint: .center),
                    lineWidth: 1
                ))
                .shadow(color: Theme.accentGlow, radius: 7, y: 4)
        case .neutral:
            shape.fill(Theme.neutralSelected)
                .shadow(color: Theme.shadow.opacity(0.5), radius: 2, y: 1)
        }
    }
}

// MARK: - KDSwitch

/// `KDSwitch`: 38 × 22; satırın tamamı tıklanır.
struct KDSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            withAnimation(Theme.spring) { configuration.isOn.toggle() }
        } label: {
            HStack(spacing: 12) {
                configuration.label
                    .frame(maxWidth: .infinity, alignment: .leading)
                KDSwitchKnob(isOn: configuration.isOn)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}

struct KDSwitchKnob: View {
    let isOn: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Capsule()
            .fill(isOn ? Theme.accent : Theme.switchOff)
            .frame(width: 38, height: 22)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle().fill(.white)
                    .frame(width: 18, height: 18)
                    .shadow(color: .black.opacity(0.3), radius: 1.5, y: 1)
                    .padding(2)
            }
            .opacity(isEnabled ? 1 : 0.4)
    }
}

extension ToggleStyle where Self == KDSwitchStyle {
    static var kdSwitch: KDSwitchStyle { KDSwitchStyle() }
}

/// Başlık + açıklama + anahtar satırı (Ayarlar, ses seçenekleri).
struct KDSwitchRow: View {
    let title: String
    var subtitle: String?
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            TitleSubtitle(title: title, subtitle: subtitle)
        }
        .toggleStyle(.kdSwitch)
    }
}

/// Satır içi başlık + meta yazısı.
struct TitleSubtitle: View {
    let title: String
    var subtitle: String?
    var titleSize: CGFloat = 13
    var titleWeight: Font.Weight = .semibold

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: titleSize, weight: titleWeight))
                .foregroundStyle(Theme.textPrimary)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .multilineTextAlignment(.leading)
    }
}

// MARK: - KDOptionRow

/// `KDOptionRow`: ses/altyazı parçaları ve sonuç listesi. Seçili = vurgu halkası + ✓.
struct KDOptionRow: View {
    let title: String
    var meta: String?
    var badge: String?
    var selected = false
    var dimmed = false
    var titleWeight: Font.Weight = .semibold
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                TitleSubtitle(title: title, subtitle: meta, titleWeight: titleWeight)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let badge { KDBadge(text: badge) }
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(minHeight: meta == nil ? 40 : 52)
            .background {
                let shape = RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous)
                if selected {
                    shape.fill(Theme.selectedFill).overlay(shape.strokeBorder(Theme.accent, lineWidth: 1.5))
                } else if hovering {
                    shape.fill(Theme.glassFill)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous))
            .opacity(dimmed ? 0.45 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - KDBadge

/// `KDBadge`: nötr, accent, bilgi (teal), uyarı (pembe).
struct KDBadge: View {
    enum Kind { case neutral, accent, info, warning, success }

    let text: String
    var kind: Kind = .neutral
    var systemImage: String?

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 9.5, weight: .bold))
            }
            Text(text)
        }
        .font(.system(size: 11, weight: .semibold))
        .lineLimit(1)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .foregroundStyle(kind == .accent ? Theme.onAccent : Theme.textPrimary)
        .background(Capsule().fill(fill))
    }

    private var fill: Color {
        switch kind {
        case .neutral: Theme.raisedFill
        case .accent: Theme.accent
        case .info: Color(hex: 0x1FB6C9, opacity: 0.28)
        case .warning: Color(hex: 0xFF3D7F, opacity: 0.26)
        case .success: Color(hex: 0x34D399, opacity: 0.22)
        }
    }
}

// MARK: - Etiketler

/// Bölüm etiketi: 11–12 / 600, büyük harf, +0,4 ("DOSYANIN İÇİNDE").
struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased(with: Locale(identifier: "tr_TR")))
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.4)
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Panel içi alan etiketi ("Boyut", "Yazı tipi").
struct FieldLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.textSecondary)
    }
}

// MARK: - KDSlider

/// Vurgu dolgulu ince kaydırıcı (ses, kutu opaklığı).
struct KDSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var trackHeight: CGFloat = 6
    var fill: Color?
    var showsKnob = true
    var onEditingChanged: (Bool) -> Void = { _ in }

    @State private var dragging = false

    var body: some View {
        GeometryReader { proxy in
            let fraction = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound)).clamped(to: 0...1)
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track).frame(height: trackHeight)
                Capsule().fill(fill ?? Theme.accent).frame(width: max(trackHeight, proxy.size.width * fraction), height: trackHeight)
                if showsKnob {
                    Circle().fill(.white)
                        .frame(width: 16, height: 16)
                        .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
                        .offset(x: proxy.size.width * fraction - 8)
                }
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if !dragging { dragging = true; onEditingChanged(true) }
                        let fraction = (gesture.location.x / max(1, proxy.size.width)).clamped(to: 0...1)
                        value = range.lowerBound + Double(fraction) * (range.upperBound - range.lowerBound)
                    }
                    .onEnded { _ in dragging = false; onEditingChanged(false) }
            )
        }
        .frame(height: 18)
        .accessibilityElement()
        .accessibilityValue("%\(Int(((value - range.lowerBound) / (range.upperBound - range.lowerBound)) * 100))")
        .accessibilityAdjustableAction { direction in
            let step = (range.upperBound - range.lowerBound) / 20
            value = (direction == .increment ? value + step : value - step).clamped(to: range)
        }
    }
}

// MARK: - Diğer

/// Dönen yükleme halkası (vurgu renginde üst kenar).
struct KDSpinner: View {
    var size: CGFloat = 22
    @State private var rotating = false

    var body: some View {
        Circle()
            .stroke(Theme.track, lineWidth: 3)
            .overlay(
                Circle().trim(from: 0, to: 0.25)
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(rotating ? 360 : 0))
            )
            .frame(width: size, height: size)
            .onAppear {
                withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { rotating = true }
            }
            .accessibilityLabel("Yükleniyor")
    }
}

/// İskelet satırı (aranıyor hali).
struct SkeletonCard: View {
    var widths: [CGFloat] = [0.7, 0.45, 0.6]
    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(widths.enumerated()), id: \.offset) { index, width in
                GeometryReader { proxy in
                    Capsule().fill(Theme.track).frame(width: proxy.size.width * width)
                }
                .frame(height: index == 0 ? 12 : 10)
            }
        }
        .padding(14)
        .glass(radius: 20)
        .opacity(pulse ? 0.55 : 1)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever()) { pulse = true }
        }
    }
}

/// Kesikli kenarlı bırakma alanı (`KDDropZone`). Sürüklenirken vurgu kenarı.
struct DropZoneBorder: View {
    var radius: CGFloat = 18
    var targeted = false

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .strokeBorder(targeted ? Theme.accent : Theme.dashedEdge, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(targeted ? Theme.accent.opacity(0.10) : Theme.glassFill.opacity(0.5))
            )
    }
}

/// Uygulama simgesi karosu (turuncu gradyan, oynat üçgeni).
struct AppGlyph: View {
    var size: CGFloat = 64

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(LinearGradient(colors: [Color(hex: 0xFFB067), Color(hex: 0xE0701C)], startPoint: .top, endPoint: .bottom))
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.45), .clear], startPoint: .top, endPoint: .center), lineWidth: 1)
            )
            .overlay(
                Image(systemName: "play.fill")
                    .font(.system(size: size * 0.38, weight: .bold))
                    .foregroundStyle(.white)
                    .offset(x: size * 0.03)
            )
            .frame(width: size, height: size)
            .shadow(color: Theme.accentGlow, radius: 13, y: 10)
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
