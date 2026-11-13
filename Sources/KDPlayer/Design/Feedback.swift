import SwiftUI
import Observation

// MARK: - KDToast

/// `KDToast`: bilgi, başarı, uyarı; aksiyonlu / aksiyonsuz. 4 sn sonra solar, üstüne gelince durur.
struct Toast: Identifiable, Equatable {
    enum Kind { case info, success, warning }

    struct Action {
        let title: String
        var emphasized = false
        let perform: () -> Void
    }

    let id = UUID()
    var kind: Kind = .info
    var title: String
    var subtitle: String?
    var actions: [Action] = []
    var duration: TimeInterval = 4

    static func == (lhs: Toast, rhs: Toast) -> Bool { lhs.id == rhs.id }
}

@Observable
final class ToastCenter {
    private(set) var current: Toast?
    var hovering = false {
        didSet { if !hovering { scheduleDismiss() } }
    }
    private var dismissTask: Task<Void, Never>?

    func show(_ toast: Toast) {
        withAnimation(Theme.spring) { current = toast }
        scheduleDismiss()
    }

    func show(_ title: String, subtitle: String? = nil, kind: Toast.Kind = .info) {
        show(Toast(kind: kind, title: title, subtitle: subtitle))
    }

    func dismiss() {
        dismissTask?.cancel()
        withAnimation(.easeOut(duration: 0.25)) { current = nil }
    }

    private func scheduleDismiss() {
        dismissTask?.cancel()
        guard let toast = current else { return }
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(toast.duration))
            guard let self, !Task.isCancelled, !self.hovering, self.current?.id == toast.id else { return }
            self.dismiss()
        }
    }
}

struct ToastView: View {
    let toast: Toast
    let center: ToastCenter

    var body: some View {
        HStack(spacing: 12) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                Text(toast.title).font(.system(size: 13, weight: .semibold))
                if let subtitle = toast.subtitle {
                    Text(subtitle).font(.system(size: 11.5)).foregroundStyle(Overlay.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: 280, alignment: .leading)
            ForEach(Array(toast.actions.enumerated()), id: \.offset) { _, action in
                Button(action.title) {
                    action.perform()
                    center.dismiss()
                }
                .buttonStyle(KDButtonStyle(variant: action.emphasized ? .primary : .glass, height: 32, fontSize: 12))
            }
        }
        .foregroundStyle(Overlay.text)
        .padding(.leading, 14)
        .padding(.trailing, toast.actions.isEmpty ? 16 : 10)
        .padding(.vertical, 10)
        .overlayGlass(radius: 20)
        .onHover { center.hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }

    @ViewBuilder private var icon: some View {
        switch toast.kind {
        case .success:
            Image(systemName: "checkmark")
                .font(.system(size: 13, weight: .heavy))
                .foregroundStyle(Theme.onAccent)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Theme.accent).shadow(color: Theme.accentGlow, radius: 7, y: 4))
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 15))
                .foregroundStyle(Color(hex: 0xFFD27A))
                .frame(width: 30, height: 30)
        case .info:
            Image(systemName: "info.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(Overlay.secondary)
                .frame(width: 30, height: 30)
        }
    }
}

// MARK: - KDHUD

/// `KDHUD`: ses, sarma, hız, altyazı gecikmesi. 1,2 sn görünür, sonra 200 ms'de solar.
/// Ardışık basışta yeniden başlamaz, değeri günceller.
enum HUDContent: Equatable {
    case volume(level: Int, muted: Bool)
    case seek(deltaSeconds: Int, position: String)
    case rate(Float)
    case subtitleDelay(ms: Int)
    case message(icon: String, text: String)
}

@Observable
final class HUDCenter {
    private(set) var content: HUDContent?
    private(set) var visible = false
    var onUndoSubtitleDelay: (() -> Void)?
    private var hideTask: Task<Void, Never>?

    func show(_ content: HUDContent) {
        self.content = content
        if !visible { withAnimation(.easeOut(duration: 0.12)) { visible = true } }
        hideTask?.cancel()
        let duration: Double = if case .subtitleDelay = content { 2.4 } else { 1.2 }
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard let self, !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { self.visible = false }
        }
    }
}

struct HUDView: View {
    let center: HUDCenter

    var body: some View {
        ZStack {
            if center.visible, let content = center.content {
                hud(for: content)
                    .transition(.opacity)
            }
        }
        .foregroundStyle(Overlay.text)
        .allowsHitTesting(center.visible)
    }

    @ViewBuilder private func hud(for content: HUDContent) -> some View {
        switch content {
        case let .volume(level, muted):
            VStack(spacing: 14) {
                Image(systemName: muted || level == 0 ? "speaker.slash.fill" : level < 34 ? "speaker.wave.1.fill" : level < 67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .frame(height: 34)
                ZStack(alignment: .leading) {
                    Capsule().fill(Overlay.track)
                    Capsule().fill(.white).frame(width: muted ? 0 : 92 * CGFloat(min(level, 100)) / 100)
                }
                .frame(width: 92, height: 6)
                Text(muted ? "Sessiz" : "%\(level)").font(.system(size: 12, weight: .semibold)).monospacedDigit()
            }
            .frame(width: 132, height: 132)
            .overlayGlass(radius: 30)
            .accessibilityLabel(muted ? "Sessiz" : "Ses yüzde \(level)")

        case let .seek(delta, position):
            HStack(spacing: 10) {
                Image(systemName: delta >= 0 ? "goforward" : "gobackward")
                    .font(.system(size: 22, weight: .semibold))
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(delta >= 0 ? "+" : "−")\(abs(delta)) sn").font(.system(size: 18, weight: .bold))
                    Text(position).font(.system(size: 11.5)).foregroundStyle(Overlay.secondary).monospacedDigit()
                }
            }
            .padding(.horizontal, 18)
            .frame(height: 64)
            .overlayGlass(in: Capsule())
            .frame(maxWidth: .infinity, alignment: delta >= 0 ? .trailing : .leading)
            .padding(.horizontal, 26)

        case let .rate(rate):
            HStack(spacing: 10) {
                Image(systemName: "gauge.with.dots.needle.67percent").font(.system(size: 17, weight: .semibold))
                Text(Format.rate(rate)).font(.system(size: 17, weight: .bold)).monospacedDigit()
                if rate != 1 {
                    Text("Ses perdesi korunur").font(.system(size: 11.5)).foregroundStyle(Overlay.secondary)
                }
            }
            .padding(.horizontal, 18)
            .frame(height: 48)
            .overlayGlass(in: Capsule())
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.top, 76)

        case let .subtitleDelay(ms):
            HStack(spacing: 10) {
                Image(systemName: "captions.bubble").font(.system(size: 16, weight: .semibold))
                (Text("Altyazı ") + Text(Format.milliseconds(ms)).foregroundColor(Theme.accent))
                    .font(.system(size: 15, weight: .semibold)).monospacedDigit()
                if let undo = center.onUndoSubtitleDelay {
                    Button("Geri al", action: undo)
                        .buttonStyle(.kd(.raised, height: 26, fontSize: 12))
                }
            }
            .padding(.leading, 18)
            .padding(.trailing, 12)
            .frame(height: 48)
            .overlayGlass(in: Capsule())
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.top, 76)

        case let .message(icon, text):
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 16, weight: .semibold))
                Text(text).font(.system(size: 14, weight: .semibold))
            }
            .padding(.horizontal, 18)
            .frame(height: 48)
            .overlayGlass(in: Capsule())
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.top, 76)
        }
    }
}

/// Oynat/duraklat geri bildirimi: ortada koyu daire içinde simge belirir, büyüyerek kaybolur (≈ 0,6 sn).
/// Video sitelerindeki alışılmış davranış; tıklamayı engellemez.
struct PlayPauseFlashView: View {
    let flash: PlayerSession.PlayPauseFlash?

    private struct Frame {
        var scale: CGFloat = 1
        var opacity: Double = 0
    }

    var body: some View {
        Image(systemName: flash?.playing == true ? "play.fill" : "pause.fill")
            .font(.system(size: 30, weight: .bold))
            .offset(x: flash?.playing == true ? 2 : 0)
            .foregroundStyle(.white)
            .frame(width: 78, height: 78)
            .background(Circle().fill(.black.opacity(0.5)))
            .keyframeAnimator(initialValue: Frame(), trigger: flash?.id) { content, frame in
                content.scaleEffect(frame.scale).opacity(frame.opacity)
            } keyframes: { _ in
                // Yalnızca doğrusal kareler: süresi çok kısa kareyle yan yana CubicKeyframe NaN üretip
                // AppKit'i çökertiyor (setFrameTransform: isfinite).
                KeyframeTrack(\.scale) {
                    LinearKeyframe(0.9, duration: 0.01)
                    LinearKeyframe(1.45, duration: 0.6, timingCurve: .easeOut)
                }
                KeyframeTrack(\.opacity) {
                    LinearKeyframe(1, duration: 0.01)
                    LinearKeyframe(1, duration: 0.15)
                    LinearKeyframe(0, duration: 0.45, timingCurve: .easeIn)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
