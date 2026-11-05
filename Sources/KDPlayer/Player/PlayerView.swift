import SwiftUI
import UniformTypeIdentifiers

/// Oynatıcı ekranı (ekran 1): video, altyazı, kontrol katmanı, paneller ve geri bildirimler.
/// Video üzerindeki her katman tema ne olursa olsun koyu camdır.
struct PlayerView: View {
    @Bindable var session: PlayerSession
    var onHome: () -> Void

    @State private var keyMonitor: Any?
    @State private var scrollMonitor: Any?
    @State private var scrollAccumulator: CGFloat = 0
    @State private var dropTargeted = false
    @Bindable private var styleStore = SubtitleStyleStore.shared

    private var player: PlayerController { session.player }
    private var showsChrome: Bool { session.controlsVisible && !session.isMini }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let subtitlePanelOpen = session.panel != nil && !session.isMini
            let roomPanelOpen = !subtitlePanelOpen && session.showsRoomPanel && session.inRoom && !session.isMini
            let panelOpen = subtitlePanelOpen || roomPanelOpen
            let contentWidth = panelOpen ? size.width - Theme.panelWidth - 32 : size.width
            let videoRect = player.videoSize.aspectFit(in: size)
            let showsSyncStrip = subtitlePanelOpen && session.panel != .appearance && session.subtitles.loaded != nil

            ZStack(alignment: .topLeading) {
                Color.black
                VideoSurface(player: player)
                    .allowsHitTesting(false)

                gestureLayer(size: size)

                // Okunabilirlik için üst ve alt karartma.
                VStack(spacing: 0) {
                    LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom).frame(height: 140)
                    Spacer()
                    LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom).frame(height: 260)
                }
                .opacity(showsChrome ? 1 : 0)
                .allowsHitTesting(false)

                SubtitleOverlay(
                    primary: session.subtitles.visibleCues(at: player.time),
                    secondary: session.subtitles.visibleSecondaryCues(at: player.time),
                    style: styleStore.style,
                    videoRect: videoRect,
                    containerSize: CGSize(width: contentWidth, height: size.height),
                    bottomInset: showsChrome ? (showsSyncStrip ? 196 : 150) : 0
                )

                if !session.isMini {
                    header
                        .padding(.horizontal, 18)
                        .padding(.top, 16)
                        .frame(width: contentWidth)
                        .opacity(showsChrome ? 1 : 0)
                }

                // Toast: sağ üst.
                VStack {
                    if let toast = session.toasts.current {
                        ToastView(toast: toast, center: session.toasts)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .frame(width: contentWidth - 36, alignment: .trailing)
                .padding(.top, 76)
                .padding(.leading, 18)

                HUDView(center: session.hud)
                    .frame(width: contentWidth, height: size.height)

                ReactionsLayer(reactions: session.reactions)
                    .frame(width: contentWidth, height: size.height)

                // Oda eylemleri: "Ayşe 42:10'a sardı".
                VStack {
                    if let event = session.roomEvent {
                        RoomEventView(event: event)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .frame(width: contentWidth)
                .padding(.top, session.toasts.current == nil ? 84 : 150)

                // Alt: kontrol çubuğu ya da senkron şeridi.
                VStack(alignment: .trailing, spacing: 12) {
                    Spacer()
                    if session.inRoom && !session.isMini {
                        WaitingChips(room: session.room)
                    }
                    if let episode = session.nextEpisode, let countdown = session.nextEpisodeCountdown, !session.inRoom {
                        NextEpisodeCard(episode: episode, countdown: countdown, session: session)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                    if session.tracksOpen && !session.isMini {
                        TrackPopover(session: session)
                            .transition(.scale(scale: 0.96, anchor: .bottomTrailing).combined(with: .opacity))
                    }
                    Group {
                        if showsSyncStrip {
                            SyncStrip(session: session)
                        } else if !session.isMini {
                            ControlBar(session: session, compact: contentWidth < (session.inRoom ? 900 : 760))
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .opacity(showsChrome || panelOpen ? 1 : 0)
                    .allowsHitTesting(showsChrome || panelOpen)
                }
                .padding(.horizontal, panelOpen ? 16 : 20)
                .padding(.bottom, panelOpen ? 16 : 20)
                .frame(width: contentWidth, height: size.height)

                if subtitlePanelOpen {
                    SubtitlePanel(session: session)
                        .padding(16)
                        .frame(width: Theme.panelWidth + 32, height: size.height)
                        .offset(x: size.width - Theme.panelWidth - 32)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                } else if roomPanelOpen {
                    RoomPanel(session: session)
                        .padding(16)
                        .frame(width: Theme.panelWidth + 32, height: size.height)
                        .offset(x: size.width - Theme.panelWidth - 32)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }

                if let pending = session.pendingSharedSubtitle {
                    SharedSubtitleCard(pending: pending, session: session)
                        .padding(.top, 76)
                        .padding(.trailing, 18)
                        .frame(width: contentWidth, alignment: .trailing)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }

                if let countdown = session.countdown {
                    CountdownOverlay(value: countdown)
                        .frame(width: size.width, height: size.height)
                }

                if session.inRoom && session.room.meta?.readyCheck == true && session.countdown == nil && session.room.localStatus != .waiting {
                    ReadyCheckView(session: session)
                        .frame(width: size.width, height: size.height)
                        .transition(.opacity)
                }

                if session.inRoom && session.room.localStatus == .waiting {
                    ZStack {
                        Color.black.opacity(0.55)
                        VStack(spacing: 12) {
                            KDSpinner()
                            Text("Onay bekleniyor").font(.system(size: 16, weight: .semibold))
                            Text("Oda kilitli; oda sahibi seni içeri alınca film başlar.").font(.system(size: 12.5)).foregroundStyle(Overlay.secondary)
                            Button("Vazgeç") { session.leaveRoom() }.buttonStyle(.kd(.raised, height: 36, fontSize: 12.5))
                        }
                        .foregroundStyle(Overlay.text)
                        .padding(24)
                        .overlayGlass(radius: 24)
                    }
                    .frame(width: size.width, height: size.height)
                }

                if session.roomSetupVisible {
                    RoomSetupSheet(session: session)
                        .frame(width: size.width, height: size.height)
                        .transition(.opacity)
                }

                if let prompt = session.resumePrompt {
                    ResumePromptView(prompt: prompt, session: session)
                        .frame(width: size.width, height: size.height)
                        .transition(.opacity)
                }

                if let error = session.blockingError {
                    ZStack {
                        Color.black.opacity(0.6)
                        ErrorCard(error: error, session: session)
                    }
                    .frame(width: size.width, height: size.height)
                    .transition(.opacity)
                }

                if dropTargeted {
                    RoundedRectangle(cornerRadius: Theme.videoWindowRadius, style: .continuous)
                        .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
                        .padding(6)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: size.width, height: size.height)
            .animation(Theme.spring, value: session.panel)
            .animation(Theme.spring, value: session.showsRoomPanel)
            .animation(Theme.spring, value: session.tracksOpen)
            .animation(Theme.spring, value: session.nextEpisodeCountdown != nil)
        }
        .clipShape(RoundedRectangle(cornerRadius: session.isMini ? 14 : Theme.videoWindowRadius, style: .continuous))
        .environment(\.colorScheme, .dark)
        .background(WindowAccessor { window in
            if session.window !== window { session.window = window }
        })
        .onContinuousHover { phase in
            if case .active = phase { session.userActivity() }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted, perform: handleDrop)
        .onAppear(perform: installMonitors)
        .onDisappear(perform: removeMonitors)
        .onChange(of: player.videoSize) { _, size in fitWindow(to: size) }
    }

    // MARK: Üst bar

    private var header: some View {
        HStack(spacing: 14) {
            if session.window?.styleMask.contains(.fullScreen) != true {
                TrafficLights(window: session.window)
            }
            if session.inRoom {
                RoomHeader(session: session).layoutPriority(-1)
            } else {
                HStack(spacing: 10) {
                    Text(session.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    if !session.detailLine.isEmpty {
                        Text(session.detailLine).font(.system(size: 12)).foregroundStyle(Overlay.secondary).lineLimit(1)
                    }
                }
                .padding(.horizontal, 16)
                .frame(height: 44)
                .glass(in: Capsule())
                .layoutPriority(-1)
            }

            Spacer(minLength: 8)

            if session.inRoom {
                KDIconButton(systemName: "bubble.left.and.bubble.right", label: "Oda paneli", active: session.showsRoomPanel && session.panel == nil) {
                    withAnimation(Theme.spring) {
                        if session.panel != nil { session.panel = nil; session.showsRoomPanel = true } else { session.showsRoomPanel.toggle() }
                    }
                }
            } else {
                Button { session.presentRoomSetup() } label: {
                    Label("Oda kur", systemImage: "person.2")
                }
                .buttonStyle(.kd(.glass, fontSize: 13))
                .help("Oda kur (⌘R)")
            }

            KDIconButton(systemName: "house", label: "Başlangıç ekranı", action: onHome)
        }
        .foregroundStyle(Overlay.text)
        .onHover { session.hoveringControls = $0 }
    }

    // MARK: Jestler

    /// Tek tık: oynat/duraklat. Çift tık: sol yarı −10 sn, sağ yarı +10 sn, orta tam ekran.
    private func gestureLayer(size: CGSize) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                SpatialTapGesture(count: 2).onEnded { value in
                    let x = value.location.x / max(size.width, 1)
                    if x < 0.33 {
                        session.seek(by: -10)
                    } else if x > 0.67 {
                        session.seek(by: 10)
                    } else {
                        session.toggleFullScreen()
                    }
                }
                .exclusively(before: TapGesture(count: 1).onEnded {
                    if session.tracksOpen {
                        withAnimation(Theme.spring) { session.tracksOpen = false }
                    } else if session.isMini {
                        session.userActivity()
                    } else {
                        session.togglePlayPause()
                    }
                })
            )
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            DispatchQueue.main.async {
                let ext = url.pathExtension.lowercased()
                if AppInfo.subtitleExtensions.contains(ext) {
                    if session.subtitles.loadUserFile(url) {
                        session.toasts.show(Toast(kind: .success, title: "Altyazı eklendi", subtitle: url.lastPathComponent))
                    }
                } else {
                    session.open(url)
                }
            }
        }
        return true
    }

    // MARK: Klavye ve kaydırma

    private func installMonitors() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Metin alanına odaklıyken tek tuşlu kısayollar devre dışı.
            if let textView = event.window?.firstResponder as? NSTextView, textView.isEditable { return event }
            guard event.window === session.window else { return event }
            return session.handleKey(event) ? nil : event
        }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard event.window === session.window, session.panel == nil, !session.tracksOpen,
                  event.hasPreciseScrollingDeltas, event.momentumPhase.isEmpty,
                  abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) else { return event }
            // İki parmak dikey kaydırma: ses.
            scrollAccumulator += event.scrollingDeltaY
            if abs(scrollAccumulator) >= 6 {
                session.changeVolume(by: scrollAccumulator > 0 ? 2 : -2)
                scrollAccumulator = 0
            }
            return nil
        }
    }

    /// İlk kare gelince pencereyi videonun en-boy oranına getirir (genişlik sabit, tam ekranda değil).
    private func fitWindow(to videoSize: CGSize) {
        guard let window = session.window, videoSize.width > 0, videoSize.height > 0,
              !window.styleMask.contains(.fullScreen), !session.isMini else { return }
        let screen = window.screen?.visibleFrame ?? .zero
        var frame = window.frame
        let height = min(frame.width * videoSize.height / videoSize.width, screen.height > 0 ? screen.height : .infinity)
        let width = height * videoSize.width / videoSize.height
        guard abs(height - frame.height) > 2 else { return }
        frame.origin.y += frame.height - height
        frame.origin.x += (frame.width - width) / 2
        frame.size = CGSize(width: width, height: height)
        window.setFrame(frame, display: true, animate: true)
    }

    private func removeMonitors() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        keyMonitor = nil
        scrollMonitor = nil
    }
}
