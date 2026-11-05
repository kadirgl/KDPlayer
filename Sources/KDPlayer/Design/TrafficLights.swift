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
