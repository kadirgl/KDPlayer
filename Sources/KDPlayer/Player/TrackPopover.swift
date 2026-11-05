import SwiftUI
import UniformTypeIdentifiers

/// Ses ve altyazı parçaları (ekran 5): iki sütunlu popover.
struct TrackPopover: View {
    @Bindable var session: PlayerSession
    /// Pencerede kalan alan: 44 altyazılı, 12 sesli remux'larda liste kayar, popover taşmaz.
    var maxWidth: CGFloat = 680
    var maxHeight: CGFloat = .infinity
    @AppStorage(SettingsKey.rememberTrackLanguages) private var remember = true

    private var player: PlayerController { session.player }
    private var subtitles: SubtitleService { session.subtitles }

    var body: some View {
        VStack(spacing: 12) {
            if compactHeight {
                // Alçak pencere: listeler ayrı ayrı kayınca birkaç satıra iner; popover tek parça kayar.
                ScrollView {
                    columns.fixedSize(horizontal: false, vertical: true)
                }
                .scrollIndicators(.automatic)
            } else {
                columns.fixedSize(horizontal: false, vertical: !needsScrolling)
            }
            Divider().overlay(Color.white.opacity(0.1))
            HStack(spacing: 12) {
                Toggle(isOn: $remember) {
                    (Text("Tüm filmlerde hatırla: ") + Text(rememberSummary).fontWeight(.semibold))
                        .font(.system(size: 12.5))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .toggleStyle(.checkbox)
                .tint(Theme.accent)
                .layoutPriority(1)
                Spacer(minLength: 8)
                if width > 600 {
                    (Text("Kısayol: ") + Text("A").fontWeight(.semibold) + Text(" ses · ") + Text("S").fontWeight(.semibold) + Text(" altyazı"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Overlay.tertiary)
                        .fixedSize()
                }
            }
            .padding(.horizontal, 4)
        }
        .foregroundStyle(Overlay.text)
        .padding(16)
        .frame(width: width)
        .frame(maxHeight: needsScrolling ? max(compactHeight ? 200 : 260, maxHeight) : nil)
        .overlayGlass(radius: 26)
        .onHover { session.hoveringControls = $0 }
        .onChange(of: player.currentAudioID) { rememberChoice() }
        .onChange(of: subtitles.loaded?.language) { rememberChoice() }
    }

    private var columns: some View {
        HStack(alignment: .top, spacing: 14) {
            audioColumn.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            subtitleColumn.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private var width: CGFloat { max(320, min(680, maxWidth)) }
    private var narrow: Bool { width < 600 }
    private var compactHeight: Bool { needsScrolling && maxHeight < 440 }
    private var listsScroll: Bool { needsScrolling && !compactHeight }

    /// Satırların tahmini yüksekliği pencereye sığmıyorsa listeler kendi içinde kayar.
    private var needsScrolling: Bool {
        let audio = 52 * CGFloat(max(1, player.audioTracks.count)) + 120
        let subtitleRows = player.embeddedSubtitles.count + (subtitles.loaded != nil ? 1 : 0) + 1
        let subtitle = 52 * CGFloat(subtitleRows) + 190
        return max(audio, subtitle) + 90 > maxHeight
    }

    // MARK: Ses

    private var audioColumn: some View {
        VStack(alignment: .leading, spacing: 2) {
            ColumnTitle(icon: "speaker.wave.2.fill", title: "Ses", count: player.audioTracks.count)
            TrackList(scrolls: listsScroll) {
                if player.audioTracks.isEmpty {
                    Text("Ses parçası yok").font(.system(size: 12.5)).foregroundStyle(Overlay.secondary).padding(12)
                }
                ForEach(player.audioTracks) { track in
                    KDOptionRow(
                        title: track.audioTitle,
                        meta: track.meta.isEmpty ? nil : track.meta,
                        badge: track.isCommentary ? "Yorum" : nil,
                        selected: track.id == player.currentAudioID,
                        dimmed: track.isUnsupported
                    ) { player.selectAudio(track.id) }
                    .id(track.id)
                }
            }
            .scrollTarget(player.currentAudioID)

            VStack(spacing: 10) {
                HStack {
                    Text("Ses gecikmesi").font(.system(size: 13))
                    Spacer()
                    KDStepper(value: Binding(get: { player.audioDelay }, set: { player.setAudioDelay($0) }), step: 50, label: "Sesi 50 ms")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .glass(radius: 16)
            .padding(.top, 8)
        }
    }

    // MARK: Altyazı

    private var subtitleColumn: some View {
        VStack(alignment: .leading, spacing: 2) {
            ColumnTitle(icon: "captions.bubble.fill", title: "Altyazı", count: player.embeddedSubtitles.count)
            TrackList(scrolls: listsScroll) {
                KDOptionRow(title: "Kapalı", selected: !subtitles.enabled || !subtitles.hasSubtitle, titleWeight: .medium) {
                    subtitles.turnOff()
                }
                .id(Int32(-1))
                if let loaded = subtitles.loaded {
                    SectionLabel(loaded.source == .openSubtitles ? "İnternetten" : "Harici")
                    KDOptionRow(
                        title: "\(Language.name(for: loaded.language) ?? "Altyazı") · \(loaded.source.title)",
                        meta: loaded.score.map { "%\($0) eşleşme · \(loaded.name)" } ?? loaded.name,
                        selected: subtitles.enabled
                    ) { subtitles.turnOn() }
                }
                if !player.embeddedSubtitles.isEmpty {
                    SectionLabel("Dosyanın içinde")
                    ForEach(session.sortedEmbeddedSubtitles) { track in
                        KDOptionRow(
                            title: track.isForced ? "\(track.languageName) · Zorunlu" : track.languageName,
                            meta: track.meta,
                            badge: track.isForced ? "Forced" : nil,
                            selected: subtitles.enabled && subtitles.embeddedTrackID == track.id
                        ) { subtitles.selectEmbedded(track) }
                        .id(track.id)
                    }
                }
            }
            .scrollTarget(subtitles.enabled ? subtitles.embeddedTrackID : nil)

            HStack(spacing: 6) {
                Button {
                    session.tracksOpen = false
                    session.togglePanel(.find)
                } label: {
                    Label(narrow ? "Ara" : "Daha fazla ara", systemImage: "magnifyingglass")
                }
                .buttonStyle(.kd(.glass, fontSize: 12.5, fullWidth: true))
                Button { pickSubtitle(secondary: false) } label: {
                    Label(narrow ? "Dosya" : "Dosyadan ekle", systemImage: "doc.badge.plus")
                }
                .buttonStyle(.kd(.glass, fontSize: 12.5, fullWidth: true))
            }
            .padding(.top, 6)

            Toggle(isOn: Binding(
                get: { subtitles.secondary != nil },
                set: { on in on ? pickSubtitle(secondary: true) : subtitles.clearSecondary() }
            )) {
                TitleSubtitle(
                    title: subtitles.secondary.map { "İkinci altyazı · \(Language.name(for: $0.language) ?? $0.name)" } ?? "İkinci altyazı",
                    subtitle: "Üstte küçük, birincil altta",
                    titleWeight: .regular
                )
            }
            .toggleStyle(.kdSwitch)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .glass(radius: 16)
            .padding(.top, 8)
        }
    }

    private var rememberSummary: String {
        let audio = player.audioTracks.first { $0.id == player.currentAudioID }?.languageName ?? "varsayılan"
        let subtitle: String
        if !subtitles.enabled || !subtitles.hasSubtitle {
            subtitle = "kapalı"
        } else if let id = subtitles.embeddedTrackID {
            subtitle = player.embeddedSubtitles.first { $0.id == id }?.languageName ?? "—"
        } else {
            subtitle = Language.name(for: subtitles.loaded?.language) ?? "—"
        }
        return "Ses \(audio) · Altyazı \(subtitle)"
    }

    /// "Tüm filmlerde hatırla" işaretliyse dil tercihi global ayara yazılır.
    private func rememberChoice() {
        guard remember else { return }
        if let code = player.audioTracks.first(where: { $0.id == player.currentAudioID })?.languageCode {
            UserDefaults.standard.set(code, forKey: SettingsKey.preferredAudioLanguage)
        }
        if let code = subtitles.loaded?.language {
            UserDefaults.standard.set(code, forKey: SettingsKey.preferredSubtitleLanguage)
        }
    }

    private func pickSubtitle(secondary: Bool) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = AppInfo.subtitleExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.directoryURL = session.url?.deletingLastPathComponent()
        panel.prompt = "Altyazıyı aç"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if secondary {
            subtitles.loadSecondary(url)
        } else if subtitles.loadUserFile(url) {
            session.toasts.show(Toast(kind: .success, title: "Altyazı eklendi", subtitle: url.lastPathComponent))
        }
    }
}

private struct ColumnTitle: View {
    let icon: String
    let title: String
    var count = 0

    var body: some View {
        HStack(spacing: 6) {
            Label(title, systemImage: icon)
                .font(.system(size: 15, weight: .semibold))
            if count > 3 {
                Text("\(count)").font(.system(size: 11.5, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(Overlay.secondary)
                    .padding(.horizontal, 7).frame(height: 18)
                    .background(Capsule().fill(Overlay.raised))
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 2)
        .padding(.bottom, 6)
    }
}

/// Parça listesi: sığıyorsa düz, sığmıyorsa kendi içinde kayan liste (seçili satır görünür tutulur).
private struct TrackList<Content: View>: View {
    let scrolls: Bool
    @ViewBuilder let content: Content
    private var target: Int32?

    init(scrolls: Bool, @ViewBuilder content: () -> Content) {
        self.scrolls = scrolls
        self.content = content()
    }

    func scrollTarget(_ id: Int32?) -> Self {
        var copy = self
        copy.target = id
        return copy
    }

    var body: some View {
        if scrolls {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) { content }
                        .padding(.trailing, 4)
                }
                .scrollIndicators(.automatic)
                .mask(
                    LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.03),
                                           .init(color: .black, location: 0.95), .init(color: .clear, location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                )
                .onAppear {
                    if let target { proxy.scrollTo(target, anchor: .center) }
                }
            }
            .frame(maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 2) { content }
        }
    }
}

/// −  0 ms  + adımlayıcı.
struct KDStepper: View {
    @Binding var value: Int
    var step = 50
    var label: String
    var format: (Int) -> String = { "\($0) ms" }

    var body: some View {
        HStack(spacing: 6) {
            Button { value -= step } label: { Text("−").font(.system(size: 14, weight: .bold)) }
                .buttonStyle(.kdIcon(30))
                .accessibilityLabel("\(label) geri al")
            Text(format(value))
                .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                .frame(width: 60)
            Button { value += step } label: { Text("+").font(.system(size: 14, weight: .bold)) }
                .buttonStyle(.kdIcon(30))
                .accessibilityLabel("\(label) ileri al")
        }
    }
}
