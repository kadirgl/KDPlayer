import SwiftUI
import UniformTypeIdentifiers

/// Ses ve altyazı parçaları (ekran 5): iki sütunlu popover.
struct TrackPopover: View {
    @Bindable var session: PlayerSession
    @AppStorage(SettingsKey.rememberTrackLanguages) private var remember = true

    private var player: PlayerController { session.player }
    private var subtitles: SubtitleService { session.subtitles }

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                audioColumn.frame(maxWidth: .infinity, alignment: .top)
                subtitleColumn.frame(maxWidth: .infinity, alignment: .top)
            }
            Divider().overlay(Color.white.opacity(0.1))
            HStack(spacing: 12) {
                Toggle(isOn: $remember) {
                    (Text("Tüm filmlerde hatırla: ") + Text(rememberSummary).fontWeight(.semibold))
                        .font(.system(size: 12.5))
                }
                .toggleStyle(.checkbox)
                .tint(Theme.accent)
                Spacer()
                (Text("Kısayol: ") + Text("A").fontWeight(.semibold) + Text(" ses · ") + Text("S").fontWeight(.semibold) + Text(" altyazı"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Overlay.tertiary)
            }
            .padding(.horizontal, 4)
        }
        .foregroundStyle(Overlay.text)
        .padding(16)
        .frame(width: 680)
        .overlayGlass(radius: 26)
        .onHover { session.hoveringControls = $0 }
        .onChange(of: player.currentAudioID) { rememberChoice() }
        .onChange(of: subtitles.loaded?.language) { rememberChoice() }
    }

    // MARK: Ses

    private var audioColumn: some View {
        VStack(alignment: .leading, spacing: 2) {
            ColumnTitle(icon: "speaker.wave.2.fill", title: "Ses")
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
            }

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
            ColumnTitle(icon: "captions.bubble.fill", title: "Altyazı")
            KDOptionRow(title: "Kapalı", selected: !subtitles.enabled || !subtitles.hasSubtitle, titleWeight: .medium) {
                subtitles.turnOff()
            }
            if !player.embeddedSubtitles.isEmpty {
                SectionLabel("Dosyanın içinde")
                ForEach(player.embeddedSubtitles) { track in
                    KDOptionRow(
                        title: track.isForced ? "\(track.languageName) · Zorunlu" : track.languageName,
                        meta: track.meta,
                        badge: track.isForced ? "Forced" : nil,
                        selected: subtitles.enabled && subtitles.embeddedTrackID == track.id
                    ) { subtitles.selectEmbedded(track) }
                }
            }
            if let loaded = subtitles.loaded {
                SectionLabel(loaded.source == .openSubtitles ? "İnternetten" : "Harici")
                KDOptionRow(
                    title: "\(Language.name(for: loaded.language) ?? "Altyazı") · \(loaded.source.title)",
                    meta: loaded.score.map { "%\($0) eşleşme · \(loaded.name)" } ?? loaded.name,
                    selected: subtitles.enabled
                ) { subtitles.turnOn() }
            }
            HStack(spacing: 6) {
                Button {
                    session.tracksOpen = false
                    session.togglePanel(.find)
                } label: {
                    Label("Daha fazla ara", systemImage: "magnifyingglass")
                }
                .buttonStyle(.kd(.glass, fontSize: 12.5, fullWidth: true))
                Button { pickSubtitle(secondary: false) } label: {
                    Label("Dosyadan ekle", systemImage: "doc.badge.plus")
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

    var body: some View {
        Label(title, systemImage: icon)
            .font(.system(size: 15, weight: .semibold))
            .padding(.horizontal, 12)
            .padding(.top, 2)
            .padding(.bottom, 6)
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
