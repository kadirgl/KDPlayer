import SwiftUI

/// Alt kontrol çubuğu (ekran 1): scrubber, ±10 sn, oynat, hız, "EN · TR", altyazı, PiP, tam ekran.
struct ControlBar: View {
    @Bindable var session: PlayerSession
    var compact = false

    private var player: PlayerController { session.player }

    var body: some View {
        #if DEBUG
        let _ = PerfCounters.controlBar += 1
        #endif
        VStack(spacing: 12) {
            TimeRow(session: session)

            HStack(spacing: 0) {
                HStack(spacing: 10) {
                    KDIconButton(systemName: volumeIcon, label: player.muted ? "Sesi aç" : "Sessiz") { session.toggleMute() }
                    if session.inRoom {
                        RoomSyncStatus(room: session.room)
                    } else if !compact {
                        KDSlider(
                            value: Binding(get: { Double(player.muted ? 0 : player.volume) }, set: { player.setVolume(Int($0)) }),
                            range: 0...100, trackHeight: 5, fill: .white, showsKnob: false
                        )
                        .frame(width: 96)
                        .accessibilityLabel("Ses düzeyi")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 14) {
                    KDIconButton(systemName: "gobackward.10", label: "10 saniye geri") { session.seek(by: -10) }
                    PlayButton(isPlaying: player.isPlaying, size: 60) { session.togglePlayPause() }
                    KDIconButton(systemName: "goforward.10", label: "10 saniye ileri") { session.seek(by: 10) }
                }

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

                    KDIconButton(systemName: "captions.bubble", label: "Altyazı paneli", active: session.panel != nil || session.subtitles.hasSubtitle && session.subtitles.enabled) {
                        session.togglePanel(.find)
                    }
                    if !compact {
                        KDIconButton(systemName: "pip.enter", label: "Resim içinde resim") { session.toggleMini() }
                    }
                    KDIconButton(systemName: "arrow.up.left.and.arrow.down.right", label: "Tam ekran") { session.toggleFullScreen() }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .foregroundStyle(Overlay.text)
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 14)
        .frame(maxWidth: 880)
        .overlayGlass(radius: 30)
        .onHover { session.hoveringControls = $0 }
    }

    private var volumeIcon: String {
        if player.muted || player.volume == 0 { return "speaker.slash.fill" }
        return player.volume < 34 ? "speaker.wave.1.fill" : player.volume < 67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
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

/// Zamana bağlı satır: saniyede birkaç kez yalnızca bu kısım yeniden çizilir, kontrol çubuğunun tamamı değil.
private struct TimeRow: View {
    let session: PlayerSession

    var body: some View {
        let player = session.player
        HStack(spacing: 14) {
            Text(Format.time(player.time))
                .font(.system(size: 12.5, weight: .semibold))
                .frame(width: 58, alignment: .leading)
            Scrubber(session: session)
            Text(Format.remaining(player.remaining))
                .font(.system(size: 12.5))
                .foregroundStyle(Overlay.secondary)
                .frame(width: 58, alignment: .trailing)
        }
        .monospacedDigit()
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
    static let rates: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]

    var body: some View {
        Button {
            let rates = Self.rates
            let index = rates.firstIndex { $0 >= session.player.rate - 0.01 } ?? 2
            session.setRate(rates[(index + 1) % rates.count])
        } label: {
            Text(Format.rate(session.player.rate)).frame(minWidth: 22)
        }
        .buttonStyle(.kdPill())
        .contextMenu {
            ForEach(Self.rates, id: \.self) { rate in
                Button(Format.rate(rate)) { session.setRate(rate) }
            }
        }
        .accessibilityLabel("Oynatma hızı \(Format.rate(session.player.rate))")
        .help("Oynatma hızı ([ / ] , \\ normal)")
    }
}

// MARK: - Scrubber

/// `KDScrubber`: bölüm işaretli; üstüne gelince zaman + bölüm önizlemesi.
struct Scrubber: View {
    let session: PlayerSession

    @State private var hoverX: CGFloat?
    @State private var dragFraction: Double?

    private var player: PlayerController { session.player }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let progress = dragFraction ?? player.progress
            ZStack(alignment: .leading) {
                Capsule().fill(Overlay.track).frame(height: 6)
                Capsule().fill(Theme.accent)
                    .frame(width: max(6, width * progress), height: 6)
                    .shadow(color: Theme.accentGlow, radius: 5)
                ForEach(player.chapters.dropFirst()) { chapter in
                    if player.duration > 0 {
                        Rectangle().fill(.black.opacity(0.45))
                            .frame(width: 2, height: 8)
                            .offset(x: width * chapter.start / player.duration - 1)
                    }
                }
                Circle().fill(.white)
                    .frame(width: 16, height: 16)
                    .shadow(color: .black.opacity(0.5), radius: 4, y: 2)
                    .offset(x: width * progress - 8)
                if let marker = session.lastSeekMarker, player.duration > 0, let member = session.room.member(marker.memberID) {
                    KDAvatar(initial: member.initial, color: member.color, size: 20)
                        .offset(x: width * marker.seconds / player.duration - 10, y: -24)
                        .transition(.scale.combined(with: .opacity))
                        .help("\(member.name) buraya sardı")
                }
            }
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
            .overlay(alignment: .topLeading) {
                if let hoverX, player.duration > 0 {
                    let fraction = Double((hoverX / max(width, 1)).clamped(to: 0...1))
                    let seconds = fraction * player.duration
                    ScrubPreview(time: seconds, chapter: player.chapters.count > 1 ? player.chapter(at: seconds) : nil)
                        .fixedSize()
                        .alignmentGuide(.leading) { dimensions in dimensions.width / 2 - hoverX }
                        .alignmentGuide(.top) { dimensions in dimensions.height + 14 }
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
