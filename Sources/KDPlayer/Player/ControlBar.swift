import SwiftUI

/// Alt kontrol çubuğu: kullanıcıların video sitelerinden alışık olduğu düzen. Tam genişlikte ince zaman çubuğu,
/// altında tek satır: solda oynat · ses · süre (· bölüm), sağda parçalar · altyazı · ayarlar · PiP · tam ekran.
/// Cam kart yok; okunabilirliği alttaki karartma sağlar. ±10 sn klavyede (← →) ve çift tıkta.
struct ControlBar: View {
    @Bindable var session: PlayerSession
    var compact = false

    @State private var fullScreen = false

    private var player: PlayerController { session.player }

    var body: some View {
        #if DEBUG
        let _ = PerfCounters.controlBar += 1
        #endif
        VStack(spacing: 2) {
            Scrubber(session: session)

            HStack(spacing: 2) {
                BarButton(systemName: player.isPlaying ? "pause.fill" : "play.fill",
                          label: player.isPlaying ? "Duraklat" : "Oynat", help: player.isPlaying ? "Duraklat (Space)" : "Oynat (Space)",
                          iconSize: 20) { session.togglePlayPause() }
                VolumeControl(session: session, showsSlider: !compact)
                TimeLabel(session: session, showsChapter: !compact)
                    .padding(.leading, 6)
                if session.inRoom {
                    RoomSyncStatus(room: session.room, dotOnly: compact).padding(.leading, compact ? 4 : 10)
                }

                Spacer(minLength: 8)

                HStack(spacing: 8) {
                    if !compact {
                        RateButton(session: session)
                    }
                    Button { session.toggleTracks() } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "waveform").font(.system(size: 13, weight: .semibold))
                            Text(trackLabel)
                        }
                    }
                    .buttonStyle(.kdPill(expanded: session.tracksOpen))
                    .accessibilityLabel("Ses ve altyazı parçaları: \(trackAccessibility)")
                    .help("Ses ve altyazı parçaları (A / S)")

                    KDIconButton(systemName: "captions.bubble", label: "Altyazı paneli",
                                 active: session.panel != nil || session.subtitles.hasSubtitle && session.subtitles.enabled) {
                        session.togglePanel(.find)
                    }
                    if !compact {
                        KDIconButton(systemName: "pip.enter", label: "Resim içinde resim") { session.toggleMini() }
                    }
                    KDIconButton(systemName: fullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                                 label: fullScreen ? "Tam ekrandan çık" : "Tam ekran") {
                        session.toggleFullScreen()
                    }
                }
            }
            .frame(height: 44)
        }
        .foregroundStyle(Overlay.text)
        .onHover { session.hoveringControls = $0 }
        .onAppear { fullScreen = session.window?.styleMask.contains(.fullScreen) == true }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { note in
            if (note.object as? NSWindow) === session.window { fullScreen = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { note in
            if (note.object as? NSWindow) === session.window { fullScreen = false }
        }
    }

    private var currentAudio: MediaTrack? { player.audioTracks.first { $0.id == player.currentAudioID } }

    private var subtitleCode: String? {
        let subtitles = session.subtitles
        guard subtitles.enabled else { return nil }
        if let id = subtitles.embeddedTrackID { return player.embeddedSubtitles.first { $0.id == id }?.languageCode }
        return subtitles.loaded?.language
    }

    /// "EN · TR"
    private var trackLabel: String {
        let audio = Language.short(for: currentAudio?.language) ?? "Ses"
        let subtitle = Language.short(for: subtitleCode) ?? "—"
        return "\(audio) · \(subtitle)"
    }

    private var trackAccessibility: String {
        let audio = currentAudio?.languageName ?? "varsayılan"
        let subtitle = Language.name(for: subtitleCode) ?? "kapalı"
        return "\(audio) ses, \(subtitle) altyazı"
    }
}

/// Arka plansız simge butonu; üstüne gelince hafif daire. `indicator`: altında vurgu çizgisi (altyazı açık).
struct BarButton: View {
    let systemName: String
    let label: String
    var help: String?
    var iconSize: CGFloat = 17
    var indicator = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: iconSize, weight: .semibold))
                .frame(width: 40, height: 40)
                .background(Circle().fill(Color.white.opacity(hovering ? 0.12 : 0)))
                .overlay(alignment: .bottom) {
                    if indicator {
                        Capsule().fill(Theme.accent).frame(width: 18, height: 3).offset(y: -3)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(PressScale())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityLabel(label)
        .help(help ?? label)
    }
}

/// Ses simgesi; üstüne gelince yanında ses çubuğu açılır.
private struct VolumeControl: View {
    let session: PlayerSession
    var showsSlider = true

    @State private var expanded = false
    @State private var dragging = false

    private var player: PlayerController { session.player }

    var body: some View {
        HStack(spacing: 0) {
            BarButton(systemName: volumeIcon, label: player.muted ? "Sesi aç" : "Sessiz", help: player.muted ? "Sesi aç (M)" : "Sessiz (M)") {
                session.toggleMute()
            }
            if showsSlider {
                KDSlider(
                    value: Binding(get: { Double(player.muted ? 0 : player.volume) }, set: { player.setVolume(Int($0)) }),
                    range: 0...100, trackHeight: 4, fill: .white, showsKnob: expanded || dragging,
                    onEditingChanged: { dragging = $0 }
                )
                .frame(width: expanded || dragging ? 76 : 0, height: 24)
                .padding(.trailing, expanded || dragging ? 8 : 0)
                .opacity(expanded || dragging ? 1 : 0)
                .clipped()
                .accessibilityLabel("Ses düzeyi")
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering in withAnimation(.easeOut(duration: 0.18)) { expanded = hovering } }
    }

    private var volumeIcon: String {
        if player.muted || player.volume == 0 { return "speaker.slash.fill" }
        return player.volume < 34 ? "speaker.wave.1.fill" : player.volume < 67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
    }
}

/// "0:39 / 3:12 · Bölüm adı". Zamanı yalnızca bu küçük görünüm okur (çubuğun tamamı saniyede yeniden çizilmez).
private struct TimeLabel: View {
    let session: PlayerSession
    var showsChapter = true

    var body: some View {
        let player = session.player
        HStack(spacing: 6) {
            Text(Format.time(player.time)) + Text(" / ").foregroundColor(Overlay.tertiary)
                + Text(Format.time(player.duration)).foregroundColor(Overlay.secondary)
            if showsChapter, player.chapters.count > 1, let chapter = player.chapter(at: player.time) {
                Text("·").foregroundStyle(Overlay.tertiary)
                Text(chapter.name).foregroundStyle(Overlay.secondary).lineLimit(1)
            }
        }
        .font(.system(size: 13, weight: .medium))
        .monospacedDigit()
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}

/// Birincil oynat butonu: 60 (oynatıcı), 52 (oda).
struct PlayButton: View {
    let isPlaying: Bool
    var size: CGFloat = 60
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: size * 0.36, weight: .bold))
                .foregroundStyle(Theme.onAccent)
                .offset(x: isPlaying ? 0 : size * 0.03)
                .frame(width: size, height: size)
                .background(
                    Circle().fill(Theme.accent)
                        .overlay(Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.45), .clear], startPoint: .top, endPoint: .center), lineWidth: 1))
                        .shadow(color: Theme.accentGlow, radius: 11, y: 8)
                )
                .contentShape(Circle())
        }
        .buttonStyle(PressScale())
        .accessibilityLabel(isPlaying ? "Duraklat" : "Oynat")
        .help(isPlaying ? "Duraklat (Space)" : "Oynat (Space)")
    }
}

struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// "1×" hapı: tıklayınca sıradaki hız; sağ tıkta liste.
struct RateButton: View {
    let session: PlayerSession

    var body: some View {
        Button {
            let rates = PlaybackRate.rates
            let index = rates.firstIndex { $0 >= session.player.rate - 0.01 } ?? 2
            session.setRate(rates[(index + 1) % rates.count])
        } label: {
            Text(Format.rate(session.player.rate)).frame(minWidth: 22)
        }
        .buttonStyle(.kdPill())
        .contextMenu {
            ForEach(PlaybackRate.rates, id: \.self) { rate in
                Button(Format.rate(rate)) { session.setRate(rate) }
            }
        }
        .accessibilityLabel("Oynatma hızı \(Format.rate(session.player.rate))")
        .help("Oynatma hızı ([ / ] , \\ normal)")
    }
}

/// Oynatma hızları (klavye: [ / ] , \\ normal).
enum PlaybackRate {
    static let rates: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]
}

// MARK: - Scrubber

/// Zaman çubuğu: ince (4 pt), üstüne gelince kalınlaşır ve tutamak belirir; bölüm araları işaretli,
/// imlecin üstünde zaman + bölüm önizlemesi.
struct Scrubber: View {
    let session: PlayerSession

    @State private var hoverX: CGFloat?
    @State private var dragFraction: Double?

    private var player: PlayerController { session.player }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let progress = dragFraction ?? player.progress
            let active = hoverX != nil || dragFraction != nil
            let barHeight: CGFloat = active ? 6 : 4
            ZStack(alignment: .leading) {
                Capsule().fill(Overlay.track).frame(height: barHeight)
                // Üstüne gelince imlece kadar açık dolgu: nereye atlanacağı görünür.
                if let hoverX, dragFraction == nil, hoverX > width * progress {
                    Capsule().fill(Overlay.buffered).frame(width: hoverX.clamped(to: 0...width), height: barHeight)
                }
                Capsule().fill(Theme.accent)
                    .frame(width: max(barHeight, width * progress), height: barHeight)
                ForEach(player.chapters.dropFirst()) { chapter in
                    if player.duration > 0 {
                        Rectangle().fill(.black.opacity(0.55))
                            .frame(width: 2, height: barHeight)
                            .offset(x: width * chapter.start / player.duration - 1)
                    }
                }
                Circle().fill(Theme.accent)
                    .frame(width: 14, height: 14)
                    .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
                    .scaleEffect(active ? 1 : 0.01)
                    .offset(x: width * progress - 7)
                if let marker = session.lastSeekMarker, player.duration > 0, let member = session.room.member(marker.memberID) {
                    KDAvatar(initial: member.initial, color: member.color, size: 20)
                        .offset(x: width * marker.seconds / player.duration - 10, y: -24)
                        .transition(.scale.combined(with: .opacity))
                        .help("\(member.name) buraya sardı")
                }
            }
            .animation(.easeOut(duration: 0.12), value: active)
            .frame(height: proxy.size.height)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location): hoverX = location.x
                case .ended: hoverX = nil
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        dragFraction = Double((value.location.x / max(width, 1)).clamped(to: 0...1))
                        hoverX = value.location.x
                        session.userActivity()
                    }
                    .onEnded { value in
                        let fraction = Double((value.location.x / max(width, 1)).clamped(to: 0...1))
                        session.seek(to: fraction * player.duration)
                        dragFraction = nil
                    }
            )
            .overlay {
                // İmlecin tam üstünde, çubuğun üstünde ortalı; kenarlarda pencereden taşmaz.
                if let hoverX, player.duration > 0 {
                    let fraction = Double((hoverX / max(width, 1)).clamped(to: 0...1))
                    let seconds = fraction * player.duration
                    let chapter = player.chapters.count > 1 ? player.chapter(at: seconds) : nil
                    let margin: CGFloat = chapter == nil ? 32 : 90
                    ScrubPreview(time: seconds, chapter: chapter)
                        .fixedSize()
                        .position(x: hoverX.clamped(to: min(margin, width / 2)...max(width - margin, width / 2)), y: -14)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
        }
        .frame(height: 18)
        .accessibilityElement()
        .accessibilityLabel("Konum")
        .accessibilityValue("\(Format.time(player.time)) / \(Format.time(player.duration))")
        .accessibilityAdjustableAction { direction in
            session.seek(by: direction == .increment ? 10 : -10)
        }
    }
}

private struct ScrubPreview: View {
    let time: Double
    let chapter: PlayerController.Chapter?

    var body: some View {
        HStack(spacing: 8) {
            Text(Format.time(time)).font(.system(size: 12, weight: .semibold)).monospacedDigit()
            if let chapter {
                Text(chapter.name).font(.system(size: 11.5)).foregroundStyle(Overlay.secondary).lineLimit(1)
            }
        }
        .foregroundStyle(Overlay.text)
        .padding(.horizontal, 12)
        .frame(height: 30)
        .overlayGlass(radius: 15)
    }
}
