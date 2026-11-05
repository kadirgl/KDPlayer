import SwiftUI
import AppKit

/// Tasarımdaki gibi içeriğin başlık satırında duran pencere düğmeleri (kapat, küçült, tam ekran).
/// Sistem düğmeleri gizlenir; üstüne gelince simgeler, pencere pasifken gri.
struct TrafficLights: View {
    let window: NSWindow?

    @State private var hovering = false
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        HStack(spacing: 8) {
            light(color: Color(hex: 0xFF5F57), symbol: "xmark", label: "Kapat") { window?.performClose(nil) }
            light(color: Color(hex: 0xFEBC2E), symbol: "minus", label: "Küçült") { window?.miniaturize(nil) }
            light(color: Color(hex: 0x28C840), symbol: "arrow.up.left.and.arrow.down.right", label: "Tam ekran") { window?.toggleFullScreen(nil) }
        }
        .padding(.leading, 6)
        .onHover { hovering = $0 }
    }

    private func light(color: Color, symbol: String, label: String, action: @escaping () -> Void) -> some View {
        let active = activeState != .inactive || hovering
        return Button(action: action) {
            Circle()
                .fill(active ? color : Color.gray.opacity(0.45))
                .overlay(Circle().strokeBorder(.black.opacity(0.12), lineWidth: 0.5))
                .overlay(
                    Image(systemName: symbol)
                        .font(.system(size: 6.5, weight: .black))
                        .foregroundStyle(.black.opacity(0.55))
                        .opacity(hovering ? 1 : 0)
                )
                .frame(width: 12, height: 12)
                .contentShape(Circle().inset(by: -3))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

extension NSWindow {
    /// Sistem trafik ışıklarını gizler (yerlerine `TrafficLights` çizilir).
    func hideStandardButtons() {
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(type)?.isHidden = true
        }
    }
}

extension NSWindow {
    /// Pencere boyutunu ana iş parçacığını kilitlemeden canlandırır. `setFrame(_:display:animate: true)`
    /// animasyon bitene kadar (≈0,35 sn) çalışma döngüsünü durduruyor, VLC olayları ve ilk kare gecikiyordu.
    func animateFrame(to frame: NSRect, duration: TimeInterval = 0.25) {
        let number = windowNumber
        WindowFrameTargets.targets[number] = frame
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animator().setFrame(frame, display: true)
        } completionHandler: {
            if WindowFrameTargets.targets[number] == frame { WindowFrameTargets.targets[number] = nil }
        }
    }

    /// Süren animasyonun hedef boyutu (yoksa şimdiki boyut): ardışık boyutlandırmalar birbirini bozmasın.
    var targetFrame: NSRect { WindowFrameTargets.targets[windowNumber] ?? frame }
}

private enum WindowFrameTargets {
    nonisolated(unsafe) static var targets: [Int: NSRect] = [:]
}
