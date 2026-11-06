import SwiftUI
import UniformTypeIdentifiers

/// Sağ altyazı paneli (ekran 2, 6, 7): Bul · Senkron · Görünüm. 384 genişlik, sağdan kayar.
struct SubtitlePanel: View {
    @Bindable var session: PlayerSession

    private var subtitles: SubtitleService { session.subtitles }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Altyazı").font(.system(size: 18, weight: .semibold)).tracking(-0.2)
                Spacer()
                KDIconButton(systemName: "xmark", label: "Paneli kapat", size: 36) { session.togglePanel(session.panel ?? .find) }
            }
            KDSegmented(
                selection: Binding(get: { session.panel ?? .find }, set: { session.panel = $0 }),
                options: PlayerSession.PanelTab.allCases.map { ($0, $0.title) }
            )
            Group {
                switch session.panel ?? .find {
                case .find: FindTab(session: session)
                case .sync: SyncTab(session: session)
                case .appearance: AppearanceTab()
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .foregroundStyle(Overlay.text)
        .padding(18)
        .frame(width: Theme.panelWidth)
        .frame(maxHeight: .infinity)
        .overlayGlass(radius: Theme.panelRadius)
        .onHover { session.hoveringControls = $0 }
    }
}

// MARK: - Bul

private struct FindTab: View {
    @Bindable var session: PlayerSession
    @State private var dropTargeted = false
    @State private var selectedID: String?

    private var subtitles: SubtitleService { session.subtitles }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            searchField
            VideoInfoLine(player: session.player)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    content
                    if let note = subtitles.loaded?.repairNote {
                        InfoRow(icon: "character.textbox", text: "Türkçe karakterler düzeltildi", detail: note)
                    }
                    if let error = subtitles.lastError, subtitles.phase != .searching {
                        InfoRow(icon: "exclamationmark.triangle", text: error, detail: nil)
                    }
                }
            }
            .scrollIndicators(.never)

            dropZone
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Overlay.secondary)
            TextField("Altyazı ara", text: Bindable(subtitles).query)
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .onSubmit { subtitles.searchOnline() }
            Menu {
                ForEach(["tr", "en", "de", "fr", "es", "it", "ru", "ar"], id: \.self) { code in
                    Button(Language.name(for: code) ?? code) {
                        subtitles.language = code
                        subtitles.searchOnline()
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(Language.name(for: subtitles.language) ?? subtitles.language)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                }
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(Capsule().fill(Overlay.raised))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .frame(height: 44)
        .glass(in: Capsule())
    }

    @ViewBuilder private var content: some View {
        switch subtitles.phase {
        case .searching:
            SearchingState(sources: subtitles.sources)
        case .notFound where subtitles.candidates.isEmpty && !subtitles.hasSubtitle:
            NotFoundState(session: session)
        default:
            if let id = subtitles.embeddedTrackID, let track = session.player.embeddedSubtitles.first(where: { $0.id == id }) {
                EmbeddedFoundState(session: session, track: track)
            }
            if subtitles.candidates.isEmpty, subtitles.embeddedTrackID == nil {
                if subtitles.phase == .idle {
                    Button { subtitles.autoSearch() } label: {
                        Label("Altyazı bul", systemImage: "sparkle.magnifyingglass")
                    }
                    .buttonStyle(.kd(.primary, fullWidth: true))
                } else if subtitles.loaded == nil {
                    NotFoundState(session: session)
                }
            }
            if let loaded = subtitles.loaded, !subtitles.candidates.contains(where: { $0.localURL == loaded.fileURL && loaded.fileURL != nil || $0.name == loaded.name }) {
                LoadedCard(loaded: loaded)
            }
            ForEach(subtitles.candidates) { candidate in
                CandidateRow(
                    session: session,
                    candidate: candidate,
                    expanded: selectedID == candidate.id || isActive(candidate),
                    active: isActive(candidate)
                ) {
                    withAnimation(Theme.spring) { selectedID = candidate.id }
                    Task { await subtitles.preview(candidate) }
                }
            }
            if subtitles.phase != .searching, subtitles.phase != .idle || !subtitles.candidates.isEmpty {
                TurkceAltyaziRow(session: session)
            }
        }
    }

    private func isActive(_ candidate: SubtitleService.Candidate) -> Bool {
        guard let loaded = subtitles.loaded else { return false }
        if let url = loaded.fileURL, url == candidate.localURL { return true }
        return loaded.source == candidate.source && loaded.name == candidate.name
    }

    private var dropZone: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.doc")
            Text("Kendi .srt / .ass dosyanı buraya bırak")
        }
        .font(.system(size: 12.5))
        .foregroundStyle(Overlay.text.opacity(0.8))
        .frame(maxWidth: .infinity, minHeight: 44)
        .background(DropZoneBorder(radius: 18, targeted: dropTargeted))
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            loadDropped(providers)
        }
        .onTapGesture { pickFile() }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Altyazı dosyası ekle")
    }

    private func loadDropped(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            DispatchQueue.main.async {
                if session.subtitles.loadUserFile(url) {
                    session.toasts.show(Toast(kind: .success, title: "Altyazı eklendi", subtitle: url.lastPathComponent))
                }
            }
        }
        return true
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = AppInfo.subtitleExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.directoryURL = session.url?.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if subtitles.loadUserFile(url) {
            session.toasts.show(Toast(kind: .success, title: "Altyazı eklendi", subtitle: url.lastPathComponent))
        }
    }
}

private struct CandidateRow: View {
    let session: PlayerSession
    let candidate: SubtitleService.Candidate
    let expanded: Bool
    let active: Bool
    let onSelect: () -> Void

    private var subtitles: SubtitleService { session.subtitles }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(candidate.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1).truncationMode(.middle)
                    badges
                    Text(meta).font(.system(size: 11.5)).foregroundStyle(Overlay.secondary)
                }
                Spacer(minLength: 0)
                Text("%\(candidate.score)")
                    .font(.system(size: expanded ? 20 : 17, weight: .bold)).monospacedDigit()
                    .foregroundStyle(expanded ? Theme.accent : Overlay.text)
            }
            if expanded {
                if let document = subtitles.previews[candidate.id] ?? (active ? subtitles.loaded?.document : nil),
                   let cue = document.cue(nearest: session.player.time, timing: active ? subtitles.timing : .identity) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Bu sahnede · \(Format.time(session.player.time))")
                            .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(Overlay.secondary)
                        Text("“\(cue.text.replacingOccurrences(of: "\n", with: " "))”")
                            .font(.system(size: 13)).lineSpacing(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.black.opacity(0.28)))
                }
                HStack(spacing: 8) {
                    Button {
                        Task {
                            if await subtitles.load(candidate) {
                                session.toasts.show(Toast(kind: .success, title: "Altyazı değiştirildi", subtitle: candidate.name))
                            }
                        }
                    } label: {
                        if subtitles.loadingCandidateID == candidate.id {
                            ProgressView().controlSize(.small)
                        } else {
                            Text(active ? "Kullanılıyor" : "Kullan")
                        }
                    }
                    .buttonStyle(.kd(.primary, height: 38, fontSize: 13, fullWidth: true))
                    .disabled(active)
                    Button("Odaya gönder") {
                        session.toasts.show("Önce bir oda kur", subtitle: "Birlikte izleme odası açıkken altyazı herkese gönderilir")
                    }
                    .buttonStyle(.kd(.glass, height: 38, fontSize: 13))
                }
            }
        }
        .padding(12)
        .background {
            let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
            if expanded {
                shape.fill(Overlay.selected)
                    .overlay(shape.strokeBorder(Theme.accent, lineWidth: 1.5))
            } else {
                shape.fill(Theme.glassFill).glassEdge(shape, highlight: Theme.glassHighlight, edge: Theme.glassEdge)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onTapGesture(perform: onSelect)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    @ViewBuilder private var badges: some View {
        let items = badgeItems
        if !items.isEmpty {
            HStack(spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, badge in badge }
            }
        }
    }

    private var badgeItems: [KDBadge] {
        var items: [KDBadge] = []
        if candidate.hashMatch { items.append(KDBadge(text: "Birebir eşleşme", kind: .accent, systemImage: "checkmark")) }
        if candidate.releaseMatch, let release = subtitles.parsedName.release, candidate.source == .openSubtitles || candidate.source == .subdl {
            items.append(KDBadge(text: "\(release) ile uyumlu"))
        }
        if candidate.fpsMismatch { items.append(KDBadge(text: "FPS farkı otomatik düzeltilir", kind: .info)) }
        if candidate.score < 65, !candidate.hashMatch, candidate.source == .openSubtitles || candidate.source == .subdl {
            items.append(KDBadge(text: "Zaman kayması olabilir", kind: .warning))
        }
        if candidate.source == .sidecar { items.append(KDBadge(text: "Yanındaki dosya")) }
        return Array(items.prefix(2))
    }

    private var meta: String {
        var parts = [candidate.source.title, Language.name(for: candidate.language) ?? candidate.language]
        if let fps = candidate.fps { parts.append(Format.fps(fps)) }
        if candidate.downloads > 0 { parts.append("\(Format.count(candidate.downloads)) indirme") }
        return parts.joined(separator: " · ")
    }
}

private struct LoadedCard: View {
    let loaded: SubtitleService.Loaded

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark")
                .font(.system(size: 14, weight: .heavy))
                .foregroundStyle(Theme.onAccent)
                .frame(width: 36, height: 36)
                .background(Circle().fill(Theme.accent).shadow(color: Theme.accentGlow, radius: 7, y: 4))
            VStack(alignment: .leading, spacing: 3) {
                Text("\(Language.name(for: loaded.language) ?? "Altyazı") · \(loaded.source.title)").font(.system(size: 13.5, weight: .semibold))
                Text(loaded.name).font(.system(size: 11.5)).foregroundStyle(Overlay.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .glass(radius: 20)
    }
}

private struct SearchingState: View {
    let sources: [SubtitleService.SourceStatus]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                KDSpinner()
                VStack(alignment: .leading, spacing: 2) {
                    Text("Altyazı aranıyor").font(.system(size: 14, weight: .semibold))
                    Text("Film oynamaya devam ediyor").font(.system(size: 12)).foregroundStyle(Overlay.secondary)
                }
            }
            FlowChips(sources: sources)
            SkeletonCard()
            SkeletonCard(widths: [0.62, 0.4, 0.52]).opacity(0.7)
            SkeletonCard(widths: [0.74, 0.38]).opacity(0.45)
            Text("Önce dosyanın içindeki altyazılara, sonra hash ile internete bakılır. Genelde 2 saniyeden kısa sürer.")
                .font(.system(size: 12)).foregroundStyle(Overlay.secondary).lineSpacing(2)
        }
    }
}

private struct FlowChips: View {
    let sources: [SubtitleService.SourceStatus]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(sources) { source in
                HStack(spacing: 6) {
                    switch source.status {
                    case .running, .waiting:
                        Circle().fill(Theme.accent).frame(width: 6, height: 6)
                            .opacity(source.status == .running ? 1 : 0.4)
                        Text(source.status == .waiting ? "\(source.id) · sırada" : source.id)
                    case .found(let count):
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                        Text("\(source.id) · \(count)")
                    case .none:
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                        Text("\(source.id) · yok")
                    case .skipped(let reason):
                        Text("\(source.id) · \(reason)")
                    }
                }
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(Capsule().fill(fill(source.status)))
                .foregroundStyle(source.status == .waiting ? Overlay.tertiary : Overlay.text)
            }
        }
    }

    private func fill(_ status: SubtitleService.SourceStatus.Status) -> Color {
        switch status {
        case .found, .none: Color(hex: 0x34D399, opacity: 0.22)
        case .running: Overlay.raised
        case .waiting, .skipped: Overlay.glass
        }
    }
}

private struct NotFoundState: View {
    @Bindable var session: PlayerSession
    @State private var notify = false

    private var subtitles: SubtitleService { session.subtitles }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(spacing: 10) {
                Image(systemName: "captions.bubble")
                    .font(.system(size: 22))
                    .frame(width: 56, height: 56)
                    .glass(in: Circle())
                Text("\(Language.name(for: subtitles.language) ?? "") altyazı bulunamadı").font(.system(size: 15, weight: .semibold))
                Text(OpenSubtitlesClient.configuredKey == nil
                     ? "Dosyanın içinde ve yanında uygun altyazı yok. İnternette aramak için Ayarlar › Altyazı'dan OpenSubtitles anahtarı ekle."
                     : "“\(subtitles.query)” için sonuç yok. Film çok yeni olabilir.")
                    .font(.system(size: 12.5)).foregroundStyle(Overlay.secondary)
                    .multilineTextAlignment(.center).lineSpacing(2)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 14)
            .padding(.horizontal, 8)

            if let other = subtitles.preferredLanguages.dropFirst().first, other != subtitles.language {
                Button {
                    subtitles.language = other
                    subtitles.searchOnline()
                } label: {
                    HStack {
                        TitleSubtitle(title: "\(Language.name(for: other) ?? other) altyazı ara", subtitle: "İkinci dil önceliğin")
                        Spacer()
                        Text("Ara").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .glass(radius: 18)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Farklı adla ara").font(.system(size: 12, weight: .semibold)).foregroundStyle(Overlay.secondary).padding(.leading, 4)
                HStack(spacing: 8) {
                    TextField("Film adı", text: Bindable(subtitles).query)
                        .textFieldStyle(.plain).font(.system(size: 13.5))
                        .onSubmit { subtitles.searchOnline() }
                    Button("Ara") { subtitles.searchOnline() }
                        .buttonStyle(.kd(.raised, height: 34, fontSize: 12.5))
                }
                .padding(.leading, 14).padding(.trailing, 6)
                .frame(height: 44)
                .glass(in: Capsule())
            }

            Toggle(isOn: $notify) {
                TitleSubtitle(title: "\(Language.name(for: subtitles.language) ?? "") çıkınca haber ver", subtitle: "Günde bir kez kontrol edilir")
            }
            .toggleStyle(.kdSwitch)
            .padding(4)
        }
    }
}

private struct EmbeddedFoundState: View {
    let session: PlayerSession
    let track: MediaTrack

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundStyle(Theme.onAccent)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Theme.accent).shadow(color: Theme.accentGlow, radius: 7, y: 4))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Dosyadaki \(track.languageName) altyazı açıldı").font(.system(size: 14, weight: .semibold))
                    Text("Gömülü altyazı her zaman birebir senkrondur, internette aramaya gerek kalmadı.")
                        .font(.system(size: 12)).foregroundStyle(Overlay.secondary).lineSpacing(2)
                }
            }
            .padding(14)
            .glass(radius: 20)

            let tracks = session.sortedEmbeddedSubtitles
            if tracks.count > 1 {
                Text("Dosyada \(tracks.count) altyazı var")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Overlay.secondary).padding(.leading, 4)
                VStack(spacing: 0) {
                    ForEach(tracks) { item in
                        Button { session.subtitles.selectEmbedded(item) } label: {
                            HStack {
                                Text("\(item.languageName) · \(item.codec ?? "")").font(.system(size: 13, weight: item.id == track.id ? .semibold : .regular))
                                    .lineLimit(1)
                                if let label = item.extraLabel {
                                    Text(label).font(.system(size: 11.5)).foregroundStyle(Overlay.tertiary).lineLimit(1)
                                }
                                Spacer(minLength: 6)
                                if item.id == track.id {
                                    Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.accent)
                                } else if item.isImageSubtitle || item.isForced {
                                    Text(item.isForced ? "Forced" : "Görüntü").font(.system(size: 11.5)).foregroundStyle(Overlay.tertiary)
                                }
                            }
                            .padding(.horizontal, 12).padding(.vertical, 10)
                            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(item.id == track.id ? Overlay.selected : .clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(4)
                .glass(radius: 18)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Çeviri kötü ya da kaymış mı?").font(.system(size: 13, weight: .semibold))
                Button {
                    session.subtitles.searchOnline()
                } label: {
                    Label("İnternette daha iyisini ara", systemImage: "globe")
                }
                .buttonStyle(.kd(.raised, height: 38, fontSize: 12.5))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14).padding(.vertical, 12)
            .glass(radius: 18)
        }
    }
}

/// Oynatılan videonun kare hızı: altyazı seçerken sürümle (23,976 / 25 fps) karşılaştırmak için.
private struct VideoInfoLine: View {
    let player: PlayerController

    var body: some View {
        if let track = player.videoTrack, let fps = track.frameRate, fps > 0 {
            HStack(spacing: 6) {
                Image(systemName: "film").font(.system(size: 11))
                Text("Video: ") + Text(Format.fps(fps)).foregroundColor(Overlay.text).fontWeight(.semibold)
                    + Text(verbatim: track.resolutionLabel.map { " · \($0)" } ?? "")
                Spacer(minLength: 0)
            }
            .font(.system(size: 12))
            .foregroundStyle(Overlay.secondary)
            .padding(.horizontal, 14)
            .accessibilityElement(children: .combine)
            .help("Altyazının kare hızı videonunkiyle aynı olmalı; farklıysa KD Player otomatik düzeltir")
        }
    }
}

private struct InfoRow: View {
    let icon: String
    let text: String
    let detail: String?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(Theme.success)
            (Text(text).foregroundColor(Overlay.text.opacity(0.85)) + Text(detail.map { " · \($0)" } ?? "").foregroundColor(Overlay.tertiary))
                .font(.system(size: 12))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .glass(radius: 16)
    }
}

// MARK: - Senkron sekmesi

private struct SyncTab: View {
    @Bindable var session: PlayerSession
    private var subtitles: SubtitleService { session.subtitles }

    var body: some View {
        ScrollView {
            content.frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
        .scrollBounceBehavior(.basedOnSize)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !subtitles.hasSubtitle {
                Text("Senkronlamak için önce bir altyazı seç.")
                    .font(.system(size: 13)).foregroundStyle(Overlay.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    FieldLabel("Gecikme")
                    Text(Format.milliseconds(subtitles.timing.offsetMilliseconds))
                        .font(.system(size: 34, weight: .bold)).monospacedDigit()
                        .foregroundStyle(Theme.accent)
                    if subtitles.timing.scale != 1 {
                        Text(String(format: "Ölçek %.4f× · FPS farkı düzeltildi", subtitles.timing.scale))
                            .font(.system(size: 12)).foregroundStyle(Overlay.secondary)
                    }
                }
                HStack(spacing: 8) {
                    Button { session.nudgeSubtitle(by: -100) } label: { HStack(spacing: 6) { Text("−100 ms"); Kbd("G") } }
                        .buttonStyle(.kd(.glass, height: 38, fontSize: 12.5, fullWidth: true))
                    Button { session.nudgeSubtitle(by: 100) } label: { HStack(spacing: 6) { Text("+100 ms"); Kbd("H") } }
                        .buttonStyle(.kd(.glass, height: 38, fontSize: 12.5, fullWidth: true))
                }

                if subtitles.activeDocument != nil {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle(isOn: $session.listeningForSpeech) {
                            TitleSubtitle(title: "Duy ve bas", subtitle: "Bir sonraki konuşmayı duyunca Space'e bas. İki farklı noktada yaparsan FPS farkı da düzelir.")
                        }
                        .toggleStyle(.kdSwitch)
                    }
                    .padding(14)
                    .glass(radius: 18)
                } else {
                    Text("Bu altyazı dosyada görüntü olarak duruyor; yalnızca gecikme ayarlanabilir.")
                        .font(.system(size: 12)).foregroundStyle(Overlay.secondary)
                }

                Button("Sıfırla") { subtitles.resetTiming() }
                    .buttonStyle(.kd(.glass, height: 40, fontSize: 12.5, fullWidth: true))
                    .disabled(subtitles.timing == .identity)

                Text("Senkron ayarı bu dosya için hatırlanır; tekrar açtığında aynı altyazı ve gecikme gelir.")
                    .font(.system(size: 11.5)).foregroundStyle(Overlay.secondary).lineSpacing(2)
            }
        }
    }
}

// MARK: - Görünüm sekmesi

private struct AppearanceTab: View {
    @Bindable private var store = SubtitleStyleStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    FieldLabel("Boyut")
                    KDSegmented(selection: $store.style.size, options: SubtitleStyle.Size.allCases.map { ($0, $0.title) }, style: .neutral)
                }
                VStack(alignment: .leading, spacing: 8) {
                    FieldLabel("Yazı tipi")
                    HStack(spacing: 8) {
                        ForEach(SubtitleStyle.FontChoice.allCases) { font in
                            StyleTile(selected: store.style.font == font, caption: font.title) {
                                Text("Aa").font(.system(size: 20, weight: .semibold, design: font.design))
                            } action: { store.style.font = font }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    FieldLabel("Stil")
                    HStack(spacing: 8) {
                        ForEach(SubtitleStyle.Look.allCases) { look in
                            StyleTile(selected: store.style.look == look, caption: look.caption) {
                                SubtitleLine(text: look.title, style: SubtitleStyle(look: look, boxOpacity: 0.6), points: 15)
                            } action: { store.style.look = look }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    FieldLabel("Renk")
                    HStack(spacing: 10) {
                        ForEach(SubtitleStyle.TextColor.allCases) { color in
                            Button { store.style.color = color } label: {
                                Circle().fill(color.color)
                                    .frame(width: 34, height: 34)
                                    .overlay(Circle().strokeBorder(.black.opacity(0.2), lineWidth: 1))
                                    .padding(3)
                                    .overlay(Circle().strokeBorder(store.style.color == color ? Theme.accent : .clear, lineWidth: 2))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(color.title)
                            .accessibilityAddTraits(store.style.color == color ? .isSelected : [])
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        FieldLabel("Kutu opaklığı")
                        Spacer()
                        Text("%\(Int(store.style.boxOpacity * 100))").font(.system(size: 12, weight: .semibold)).monospacedDigit()
                    }
                    KDSlider(value: $store.style.boxOpacity, range: 0...1)
                        .disabled(store.style.look != .box)
                        .opacity(store.style.look == .box ? 1 : 0.4)
                        .accessibilityLabel("Kutu opaklığı")
                }
                VStack(alignment: .leading, spacing: 8) {
                    FieldLabel("Konum")
                    KDSegmented(selection: $store.style.position, options: SubtitleStyle.Position.allCases.map { ($0, $0.title) }, style: .neutral)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Görünüm sadece sende değişir, odadakiler kendi ayarını kullanır. Dosyanın içindeki metin altyazılara da uygulanır; görüntü tabanlı (PGS, VobSub) altyazılar dosyadaki haliyle görünür.")
                        .font(.system(size: 11.5)).foregroundStyle(Overlay.secondary).lineSpacing(2)
                    Button("Varsayılana dön") { store.style = .default }
                        .buttonStyle(.kd(.glass, height: 40, fontSize: 12.5, fullWidth: true))
                }
                .padding(.top, 4)
            }
        }
        .scrollIndicators(.never)
    }
}

private struct StyleTile<Preview: View>: View {
    let selected: Bool
    let caption: String
    @ViewBuilder let preview: Preview
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                preview.frame(height: 30)
                Text(caption).font(.system(size: 11.5)).foregroundStyle(Overlay.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 74)
            .background {
                let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
                shape.fill(Theme.glassFill)
                    .glassEdge(shape, highlight: Theme.glassHighlight, edge: Theme.glassEdge)
                    .overlay(shape.strokeBorder(selected ? Theme.accent : .clear, lineWidth: 1.5))
            }
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(caption)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Senkron şeridi

/// Alt senkron şeridi (ekran 2): gecikme, ±100 ms, Duy ve bas ve sürüklenebilir satır blokları.
struct SyncStrip: View {
    @Bindable var session: PlayerSession
    @State private var dragStartOffset: Double?

    private let window: Double = 30
    private var subtitles: SubtitleService { session.subtitles }

    var body: some View {
        VStack(spacing: 12) {
            // Dar pencerede (panel açıkken video alanı küçülür) düğmeler kısalır, gerekirse alt satıra iner.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    offsetLabel
                    Spacer(minLength: 8)
                    buttons(compact: false)
                }
                HStack(spacing: 8) {
                    offsetLabel
                    Spacer(minLength: 6)
                    buttons(compact: true)
                }
                VStack(alignment: .leading, spacing: 8) {
                    offsetLabel
                    buttons(compact: true)
                }
            }

            timeline

            HStack(spacing: 8) {
                Text(Format.time(max(0, session.player.time - window / 2)))
                Spacer(minLength: 4)
                Text(session.listeningForSpeech ? "Konuşmayı duyduğun an Space'e bas" : "Blokları sürükleyerek ince ayar yap")
                    .foregroundStyle(session.listeningForSpeech ? Theme.accent : Overlay.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(-1)
                Spacer(minLength: 4)
                Text(Format.time(session.player.time + window / 2))
            }
            .font(.system(size: 11.5)).monospacedDigit()
            .foregroundStyle(Overlay.secondary)
        }
        .foregroundStyle(Overlay.text)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .overlayGlass(radius: Theme.panelRadius)
        .onHover { session.hoveringControls = $0 }
    }

    private var offsetLabel: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("Senkron").font(.system(size: 14, weight: .semibold))
            Text(Format.milliseconds(subtitles.timing.offsetMilliseconds))
                .font(.system(size: 22, weight: .bold)).monospacedDigit()
                .foregroundStyle(Theme.accent)
        }
        .fixedSize()
    }

    private func buttons(compact: Bool) -> some View {
        HStack(spacing: compact ? 6 : 10) {
            Button { session.nudgeSubtitle(by: -100) } label: {
                HStack(spacing: 6) { Text(compact ? "−100" : "−100 ms"); if !compact { Kbd("G") } }
            }
            .buttonStyle(.kd(.glass, height: 38, fontSize: 12.5))
            .fixedSize()
            .help("Altyazıyı 100 ms erkene al (G)")
            Button { session.nudgeSubtitle(by: 100) } label: {
                HStack(spacing: 6) { Text(compact ? "+100" : "+100 ms"); if !compact { Kbd("H") } }
            }
            .buttonStyle(.kd(.glass, height: 38, fontSize: 12.5))
            .fixedSize()
            .help("Altyazıyı 100 ms geciktir (H)")
            Button { session.listeningForSpeech.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "ear")
                    Text("Duy ve bas")
                    if !compact { Kbd("Space", onAccent: session.listeningForSpeech) }
                }
            }
            .buttonStyle(.kd(session.listeningForSpeech ? .primary : .glass, height: 38, fontSize: 12.5))
            .fixedSize()
            .help("Açıkken Space, bir sonraki altyazı satırını o ana hizalar")
        }
    }

    private var timeline: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let now = session.player.time
            let start = now - window / 2
            let cues = subtitles.activeDocument?.cues(in: start...(start + window), timing: subtitles.timing) ?? []
            let activeIDs = Set(subtitles.visibleCues(at: now).map(\.id))
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.black.opacity(0.3))
                ForEach(cues) { cue in
                    let cueStart = subtitles.timing.displayTime(for: cue.start)
                    let cueEnd = subtitles.timing.displayTime(for: cue.end)
                    let x = (cueStart - start) / window * width
                    let w = max(18, (cueEnd - cueStart) / window * width)
                    let active = activeIDs.contains(cue.id)
                    Text(cue.text.replacingOccurrences(of: "\n", with: " "))
                        .font(.system(size: 11, weight: active ? .semibold : .regular))
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .frame(width: w, height: 30, alignment: .leading)
                        .background {
                            let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
                            shape.fill(.white.opacity(active ? 0.2 : 0.14))
                                .overlay(shape.strokeBorder(active ? Theme.accent : .clear, lineWidth: 1.5))
                                .shadow(color: active ? Theme.accentGlow : .clear, radius: 7)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .offset(x: x, y: 14)
                }
                Rectangle().fill(Theme.accent)
                    .frame(width: 2)
                    .shadow(color: Theme.accentGlow, radius: 5)
                    .offset(x: width / 2 - 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        if dragStartOffset == nil { dragStartOffset = subtitles.timing.offset }
                        let delta = Double(value.translation.width / width) * window
                        subtitles.timing.offset = (((dragStartOffset ?? 0) + delta) * 1000).rounded() / 1000
                    }
                    .onEnded { _ in dragStartOffset = nil }
            )
        }
        .frame(height: 58)
        .accessibilityElement()
        .accessibilityLabel("Senkron zaman çizelgesi")
        .accessibilityValue(Format.milliseconds(subtitles.timing.offsetMilliseconds))
        .accessibilityAdjustableAction { direction in
            session.nudgeSubtitle(by: direction == .increment ? 100 : -100)
        }
    }
}

/// turkcealtyazi.org: arama tarayıcıda açılır, indirilen zip/srt İndirilenler'den kendiliğinden eklenir.
private struct TurkceAltyaziRow: View {
    @Bindable var session: PlayerSession

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: session.watchingDownloads ? "arrow.down.circle" : "globe")
                .font(.system(size: 16))
                .frame(width: 24)
                .symbolEffect(.pulse, isActive: session.watchingDownloads)
            TitleSubtitle(
                title: session.watchingDownloads ? "İndirmen bekleniyor…" : "turkcealtyazi.org'da ara",
                subtitle: session.watchingDownloads
                    ? "Tarayıcıda altyazıyı indir; zip ya da srt gelince otomatik eklenir"
                    : "Tarayıcında açılır; indirdiğin altyazı kendiliğinden eklenir"
            )
            Spacer(minLength: 6)
            if session.watchingDownloads {
                Button("Vazgeç") { session.cancelDownloadsWatch() }
                    .buttonStyle(.kd(.glass, height: 30, fontSize: 12))
                    .fixedSize()
            } else {
                Text("Aç").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .glass(radius: 18)
        .contentShape(Rectangle())
        .onTapGesture { if !session.watchingDownloads { session.searchTurkceAltyazi() } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}
