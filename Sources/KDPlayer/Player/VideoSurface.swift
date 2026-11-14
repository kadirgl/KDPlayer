import SwiftUI
import VLCKit

/// libVLC'nin çizdiği video yüzeyi (`VLCVideoView`, `NSViewRepresentable` içinde).
struct VideoSurface: NSViewRepresentable {
    let player: PlayerController

    func makeNSView(context: Context) -> VideoHostView {
        let host = VideoHostView()
        host.host(player.videoView)
        return host
    }

    func updateNSView(_ host: VideoHostView, context: Context) {
        if player.videoView.superview !== host { host.host(player.videoView) }
    }
}

/// Kalıcı VLC yüzeyini taşıyan kap: her oynatıcı ekranı aynı yüzeyi kendine alır.
final class VideoHostView: NSView {
    func host(_ view: NSView) {
        view.removeFromSuperview()
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
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
