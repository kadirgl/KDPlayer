import SwiftUI
import VLCKit

/// libVLC'nin çizdiği video yüzeyi (`VLCVideoView`, `NSViewRepresentable` içinde).
struct VideoSurface: NSViewRepresentable {
    let player: PlayerController

    func makeNSView(context: Context) -> VLCVideoView {
        let view = VLCVideoView()
        view.backColor = .black
        view.fillScreen = false
        player.mediaPlayer.drawable = view
        return view
    }

    func updateNSView(_ view: VLCVideoView, context: Context) {
        if player.mediaPlayer.drawable as? VLCVideoView !== view {
            player.mediaPlayer.drawable = view
        }
    }
}

/// Pencereye erişim (tam ekran, PiP, trafik ışıkları).
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { if let window = view.window { onWindow(window) } }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { if let window = view.window { onWindow(window) } }
    }
}

extension CGSize {
    /// Bu boyuttaki videonun `container` içine sığdırılmış dikdörtgeni.
    func aspectFit(in container: CGSize) -> CGRect {
        guard width > 0, height > 0, container.width > 0, container.height > 0 else {
            return CGRect(origin: .zero, size: container)
        }
        let scale = min(container.width / width, container.height / height)
        let size = CGSize(width: width * scale, height: height * scale)
        return CGRect(x: (container.width - size.width) / 2, y: (container.height - size.height) / 2, width: size.width, height: size.height)
    }
}
