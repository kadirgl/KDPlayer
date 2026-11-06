import Foundation
import Observation

/// Altyazı servisi: arama sırası (dosyanın içi → yanındaki dosya → internet hash → internet ad),
/// güven skoru, otomatik yükleme, senkron ve görünürdeki satırlar (spesifikasyon › Altyazı sistemi).
@Observable
final class SubtitleService {
    // MARK: Modeller

    enum Source: String, Codable {
        case embedded, sidecar, openSubtitles, subdl, turkcealtyazi, file, room

        var title: String {
            switch self {
            case .embedded: "Dosyanın içi"
            case .sidecar: "Yanındaki dosya"
            case .openSubtitles: "OpenSubtitles"
            case .subdl: "Subdl"
            case .turkcealtyazi: "turkcealtyazi.org"
            case .file: "Dosyadan"
            case .room: "Oda"
            }
        }
    }

    /// Bizim çizdiğimiz (harici) altyazı.
    struct Loaded: Equatable {
        var document: SubtitleDocument
        var name: String
        var language: String?
        var source: Source
        var fileURL: URL?
        var encodingName: String
        var repairNote: String?
        var score: Int?
        /// UTF-8'e çevrilmiş ham metin (odaya paylaşmak için).
        var rawText: String = ""
    }

    struct Candidate: Identifiable, Equatable {
        let id: String
        let name: String
        let language: String
        let source: Source
        let score: Int
        let hashMatch: Bool
        let releaseMatch: Bool
        let fpsMismatch: Bool
        let fps: Double?
        let downloads: Int
        let fileID: Int?
        let localURL: URL?
        /// Subdl indirme yolu ("/subtitle/…zip").
        var downloadPath: String? = nil

        static func == (lhs: Candidate, rhs: Candidate) -> Bool { lhs.id == rhs.id }
    }

    struct SourceStatus: Identifiable, Equatable {
        enum Status: Equatable { case waiting, running, found(Int), none, skipped(String) }
        let id: String
        var status: Status
    }

    enum Phase: Equatable {
        case idle
        case searching
        case finished
        case notFound
    }

    // MARK: Durum

    private(set) var phase: Phase = .idle
    private(set) var sources: [SourceStatus] = []
    private(set) var candidates: [Candidate] = []
    private(set) var loaded: Loaded?
    /// İkinci altyazı (üstte, %70 boyutta).
    private(set) var secondary: Loaded?
    /// Seçili gömülü parça (seçiliyse harici altyazı kapalıdır).
    private(set) var embeddedTrackID: Int32?
    /// Gömülü metin parçası dosyadan okunduysa onu biz çizeriz (kullanıcının stiliyle);
    /// okunamıyorsa (görüntü altyazı, MKV dışı kap) VLC çizer.
    private(set) var embeddedDocument: SubtitleDocument?
    var timing = SubtitleTiming() {
        didSet { if timing != oldValue { applyTiming() } }
    }
    var enabled = true
    var query = ""
    var language: String
    /// Sonuç satırı seçilince indirilip hafızada tutulan önizleme (oynatıcıya yüklenmez).
    private(set) var previews: [String: SubtitleDocument] = [:]
    private(set) var loadingCandidateID: String?
    private(set) var lastError: String?
    private(set) var remainingDownloads: Int?
    /// "Duy ve bas" ilk işaret noktası (kaynak, görüntü zamanları).
    private(set) var syncAnchor: (source: Double, display: Double)?

    // MARK: Bağlam

    @ObservationIgnored private weak var player: PlayerController?
    @ObservationIgnored private var mediaURL: URL?
    @ObservationIgnored private(set) var fileHash: String?
    @ObservationIgnored private(set) var parsedName = ParsedFilename(title: "")
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var embeddedTask: Task<Void, Never>?
    @ObservationIgnored private var extractor: EmbeddedSubtitleExtractor?
    @ObservationIgnored private var embeddedCache: [Int32: SubtitleDocument] = [:]
    @ObservationIgnored var onAutoLoaded: ((Candidate?, Loaded) -> Void)?
    @ObservationIgnored var onEmbeddedSelected: ((MediaTrack) -> Void)?
    @ObservationIgnored var onNeedsAttention: (() -> Void)?
    @ObservationIgnored var onPersist: (() -> Void)?
    @ObservationIgnored var onTimingChanged: ((SubtitleTiming) -> Void)?
    /// Altyazı (yükleme / değiştirme) değişince; oda "odanın altyazısını kullanıyor" bilgisini günceller.
    @ObservationIgnored var onSubtitleReplaced: ((Source?) -> Void)?

    init() {
        let languages = UserDefaults.standard.stringArray(forKey: SettingsKey.subtitleLanguages) ?? ["tr", "en"]
        language = languages.first ?? "tr"
    }

    var preferredLanguages: [String] {
        UserDefaults.standard.stringArray(forKey: SettingsKey.subtitleLanguages) ?? ["tr", "en"]
    }

    var hasSubtitle: Bool { loaded != nil || embeddedTrackID != nil }

    /// Bizim çizdiğimiz etkin altyazı (gömülü okunmuşsa o, yoksa harici).
    var activeDocument: SubtitleDocument? {
        embeddedTrackID != nil ? embeddedDocument : loaded?.document
    }

    /// Gömülü parçayı şu an VLC mi çiziyor (stil ayarları ona uygulanamaz).
    var embeddedRenderedByVLC: Bool { embeddedTrackID != nil && embeddedDocument == nil }

    // MARK: Oturum

    func attach(player: PlayerController) {
        self.player = player
    }

    func reset(for url: URL, hash: String?) {
        searchTask?.cancel()
        embeddedTask?.cancel()
        extractor = MatroskaSubtitleReader.canRead(url) ? EmbeddedSubtitleExtractor(url: url) : nil
        embeddedCache = [:]
        embeddedDocument = nil
        mediaURL = url
        fileHash = hash
        parsedName = ParsedFilename(filename: url.lastPathComponent)
        query = parsedName.query
        phase = .idle
        sources = []
        candidates = []
        loaded = nil
        secondary = nil
        embeddedTrackID = nil
        timing = .identity
        previews = [:]
        lastError = nil
        syncAnchor = nil
        enabled = true
        language = preferredLanguages.first ?? "tr"
    }

    /// Kaydedilmiş altyazıyı geri yükler; yoksa otomatik aramayı başlatır.
    func start(restoring record: WatchRecord?) {
        if let record, record.subtitleEnabled == false {
            enabled = false
        }
        if let record, let path = record.subtitlePath, FileManager.default.fileExists(atPath: path) {
            let url = URL(fileURLWithPath: path)
            if let loaded = try? loadFile(url, source: Source(rawValue: record.subtitleSource ?? "") ?? .file, name: record.subtitleName, language: record.subtitleLanguage) {
                self.loaded = loaded
                timing = record.subtitleTiming
                phase = .finished
                return
            }
        }
        if let record, let id = record.embeddedSubtitleID {
            searchTask = Task { @MainActor [weak self] in
                guard let self, await self.waitForTracks() else { return }
                if let track = self.player?.embeddedSubtitles.first(where: { $0.id == Int32(id) }) {
                    self.selectEmbedded(track)
                    self.timing = record.subtitleTiming
                }
            }
            return
        }
        guard UserDefaults.standard.bool(forKey: SettingsKey.subtitleAutoLoad) else { return }
        autoSearch()
    }

    // MARK: Otomatik arama

    func autoSearch() {
        searchTask?.cancel()
        phase = .searching
        let hasKey = OpenSubtitlesClient.configuredKey != nil
        sources = [
            SourceStatus(id: Source.embedded.title, status: .running),
            SourceStatus(id: Source.sidecar.title, status: .waiting),
            SourceStatus(id: Source.openSubtitles.title, status: hasKey ? .waiting : .skipped("anahtar yok")),
        ]
        if SubdlClient.configuredKey != nil {
            sources.append(SourceStatus(id: Source.subdl.title, status: .waiting))
        }
        searchTask = Task { @MainActor [weak self] in
            await self?.runPipeline()
        }
    }

    @MainActor
    private func runPipeline() async {
        let languages = preferredLanguages
        let preferEmbedded = UserDefaults.standard.bool(forKey: SettingsKey.subtitlePreferEmbedded)

        // 1. Dosyanın içi
        if await waitForTracks(), let player {
            let textTracks = player.embeddedSubtitles.filter { !$0.isImageSubtitle && !$0.isForced }
            let match = languages.lazy.compactMap { code in textTracks.first { $0.languageCode == code } }.first
            if let match, preferEmbedded {
                setStatus(Source.embedded.title, .found(1))
                selectEmbedded(match)
                phase = .finished
                onEmbeddedSelected?(match)
                sources = sources.map { $0.status == .waiting ? SourceStatus(id: $0.id, status: .skipped("gerek yok")) : $0 }
                return
            }
            setStatus(Source.embedded.title, player.embeddedSubtitles.isEmpty ? .none : .found(player.embeddedSubtitles.count))
            // Dosyada altyazı varsa ama tercih edilen dilde değilse VLC'nin otomatik seçtiğini kapat.
            if !player.embeddedSubtitles.isEmpty, embeddedTrackID == nil { player.selectEmbeddedSubtitle(-1) }
        } else {
            setStatus(Source.embedded.title, .none)
        }
        if Task.isCancelled { return }

        // 2. Yanındaki dosya
        setStatus(Source.sidecar.title, .running)
        let sidecars = findSidecars()
        if !sidecars.isEmpty {
            setStatus(Source.sidecar.title, .found(sidecars.count))
            candidates = sidecars
            let best = languages.lazy.compactMap { code in sidecars.first { $0.language == code } }.first ?? sidecars.first
            if let best, preferEmbedded, await load(best, auto: true) {
                phase = .finished
                skipRemaining()
                return
            }
        } else {
            setStatus(Source.sidecar.title, .none)
        }
        if Task.isCancelled { return }

        // 3–4. İnternet: OpenSubtitles (hash, sonra ad)
        var online: [Candidate] = []
        if let key = OpenSubtitlesClient.configuredKey {
            setStatus(Source.openSubtitles.title, .running)
            let client = OpenSubtitlesClient(apiKey: key)
            var results: [OpenSubtitlesClient.Result] = []
            do {
                if let hash = fileHash {
                    results = try await client.search(hash: hash, query: nil, season: parsedName.season, episode: parsedName.episode, languages: languages)
                }
                if !results.contains(where: \.hashMatch) {
                    let byName = try await client.search(hash: nil, query: parsedName.title, season: parsedName.season, episode: parsedName.episode, languages: languages)
                    let known = Set(results.map(\.fileID))
                    results += byName.filter { !known.contains($0.fileID) }
                }
                setStatus(Source.openSubtitles.title, results.isEmpty ? .none : .found(results.count))
            } catch {
                lastError = error.localizedDescription
                setStatus(Source.openSubtitles.title, .skipped(error is OpenSubtitlesClient.ClientError ? "sınır" : "bağlantı yok"))
            }
            online = results.map(makeCandidate)
        }
        if Task.isCancelled { return }

        // 5. Subdl: OpenSubtitles birincil dilde bir şey bulamadıysa.
        if !online.contains(where: { $0.language == languages.first }), SubdlClient.configuredKey != nil {
            setStatus(Source.subdl.title, .running)
            let found = await searchSubdl(title: parsedName.title, year: parsedName.year, season: parsedName.season,
                                          episode: parsedName.episode, languages: languages)
            setStatus(Source.subdl.title, found.map { $0.isEmpty ? .none : .found($0.count) } ?? .skipped("bağlantı yok"))
            online += found ?? []
        } else if SubdlClient.configuredKey != nil {
            setStatus(Source.subdl.title, .skipped("gerek yok"))
        }
        if Task.isCancelled { return }

        candidates = (candidates + online).sorted(by: Self.ranking(languages: languages))
        finishSearch()
    }

    /// Subdl araması; hata olursa nil (sessizce sonraki adıma geçilir).
    @MainActor
    private func searchSubdl(title: String, year: Int?, season: Int?, episode: Int?, languages: [String]) async -> [Candidate]? {
        guard let key = SubdlClient.configuredKey else { return nil }
        do {
            let results = try await SubdlClient(apiKey: key).search(title: title, year: year, season: season, episode: episode, languages: languages)
            return results.map(makeSubdlCandidate)
        } catch {
            if lastError == nil { lastError = error.localizedDescription }
            return nil
        }
    }

    @MainActor
    private func finishSearch() {
        let languages = preferredLanguages
        let primary = candidates.filter { $0.language == languages.first }
        guard let best = primary.first ?? candidates.first else {
            phase = .notFound
            onNeedsAttention?()
            return
        }
        phase = .finished
        if loaded != nil { return }
        // ≥ %60: en iyisini yükle (≥ %90 sessiz, altı "Değiştir" vurgulu). Altı: paneli aç.
        if best.score >= 60 {
            Task { @MainActor in _ = await load(best, auto: true) }
        } else {
            onNeedsAttention?()
        }
    }

    /// Kullanıcının "Farklı adla ara" ya da dil değiştirmesiyle yeniden arama (yalnızca internet:
    /// OpenSubtitles ve Subdl birlikte).
    func searchOnline() {
        searchTask?.cancel()
        let openKey = OpenSubtitlesClient.configuredKey
        let hasSubdl = SubdlClient.configuredKey != nil
        guard openKey != nil || hasSubdl else {
            lastError = OpenSubtitlesClient.ClientError.missingKey.localizedDescription
            phase = .notFound
            return
        }
        phase = .searching
        lastError = nil
        sources = []
        if openKey != nil { sources.append(SourceStatus(id: Source.openSubtitles.title, status: .running)) }
        if hasSubdl { sources.append(SourceStatus(id: Source.subdl.title, status: .running)) }
        let query = self.query
        let languages = [language]
        searchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let parsed = ParsedFilename(filename: query)
            let season = parsed.season ?? self.parsedName.season
            let episode = parsed.episode ?? self.parsedName.episode
            async let subdl: [Candidate]? = hasSubdl
                ? self.searchSubdl(title: parsed.title, year: parsed.year ?? self.parsedName.year, season: season, episode: episode, languages: languages)
                : nil
            var open: [Candidate] = []
            if let openKey {
                do {
                    let results = try await OpenSubtitlesClient(apiKey: openKey).search(
                        hash: self.fileHash, query: parsed.title, season: season, episode: episode, languages: languages
                    )
                    open = results.map(self.makeCandidate)
                    self.setStatus(Source.openSubtitles.title, results.isEmpty ? .none : .found(results.count))
                } catch {
                    self.lastError = error.localizedDescription
                    self.setStatus(Source.openSubtitles.title, .skipped("hata"))
                }
            }
            let fromSubdl = await subdl
            if hasSubdl {
                self.setStatus(Source.subdl.title, fromSubdl.map { $0.isEmpty ? .none : .found($0.count) } ?? .skipped("hata"))
            }
            if Task.isCancelled { return }
            let local = self.findSidecars().filter { $0.language == self.language }
            self.candidates = (local + open + (fromSubdl ?? [])).sorted(by: Self.ranking(languages: languages))
            self.phase = self.candidates.isEmpty ? .notFound : .finished
        }
    }

    // MARK: Yükleme

    /// Adayı indirir/okur ve oynatıcıya uygular.
    @MainActor @discardableResult
    func load(_ candidate: Candidate, auto: Bool = false) async -> Bool {
        loadingCandidateID = candidate.id
        defer { loadingCandidateID = nil }
        do {
            let document: SubtitleDocument
            let decoded: SubtitleTextDecoder.Result
            var fileURL = candidate.localURL
            if let localURL = candidate.localURL {
                (document, decoded) = try Self.read(localURL)
            } else if let fileID = candidate.fileID, let key = OpenSubtitlesClient.configuredKey {
                let (data, remaining) = try await OpenSubtitlesClient(apiKey: key, timeout: 10).download(fileID: fileID)
                remainingDownloads = remaining
                (document, decoded) = try Self.parse(data)
                fileURL = store(decoded.text, language: candidate.language, format: document.format, nextToVideo: !auto || candidate.hashMatch)
            } else if let path = candidate.downloadPath, let key = SubdlClient.configuredKey {
                let result = SubdlClient.Result(path: path, releaseName: candidate.name, language: candidate.language,
                                                hearingImpaired: false, fps: candidate.fps, season: nil, episode: nil, fullSeason: false)
                let (data, _) = try await SubdlClient(apiKey: key).download(result, episodeCode: parsedName.episodeCode)
                (document, decoded) = try Self.parse(data)
                fileURL = store(decoded.text, language: candidate.language, format: document.format, nextToVideo: !auto || candidate.hashMatch)
            } else {
                return false
            }
            if Task.isCancelled && auto { return false }
            let loaded = Loaded(
                document: document, name: candidate.name, language: candidate.language, source: candidate.source,
                fileURL: fileURL, encodingName: decoded.encodingName, repairNote: decoded.repairNote, score: candidate.score,
                rawText: decoded.text
            )
            apply(loaded, resetTiming: true)
            if candidate.fpsMismatch, let fps = candidate.fps, let videoFPS = player?.videoTrack?.frameRate {
                timing = SubtitleTiming(scale: SubtitleTiming.fps(from: fps, to: videoFPS), offset: 0)
            }
            if auto { onAutoLoaded?(candidate, loaded) }
            return true
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? "Altyazı açılamadı"
            return false
        }
    }

    /// İnternetten inen altyazıyı UTF-8 olarak saklar: ayar açıksa videonun yanına (`film.tr.srt`; başka oynatıcılar
    /// da görür, sonraki açılışta "yanındaki dosya" olur), yazılamazsa uygulamanın kendi klasörüne.
    /// `nextToVideo`: yalnızca kullanıcının seçtiği ya da birebir (hash) eşleşen altyazı videonun yanına yazılır;
    /// adı tutan ama yanlış olabilecek otomatik seçim kalıcı "yanındaki dosya"ya dönüşmesin.
    private func store(_ text: String, language: String, format: SubtitleDocument.Format, nextToVideo: Bool = true) -> URL? {
        if nextToVideo, UserDefaults.standard.bool(forKey: SettingsKey.subtitleSaveNextToVideo), let mediaURL,
           let saved = SubtitleArchive.saveNextToVideo(text: text, video: mediaURL, language: language, format: format.rawValue) {
            return saved
        }
        let name = "\(fileHash ?? UUID().uuidString).\(language).\(format.rawValue)"
        let saved = AppInfo.subtitlesDirectory.appendingPathComponent(name)
        return (try? text.write(to: saved, atomically: true, encoding: .utf8)) != nil ? saved : nil
    }

    /// turkcealtyazi.org'dan (tarayıcıda) indirilen zip/srt: altyazıyı çıkarır, videonun yanına kaydeder ve açar.
    @discardableResult
    func importDownloaded(_ url: URL) throws -> Loaded {
        let raw = try Data(contentsOf: url)
        let (data, innerName) = try SubtitleArchive.subtitleData(from: raw, episode: parsedName.episodeCode)
        let (document, decoded) = try Self.parse(data)
        let name = innerName ?? url.lastPathComponent
        let detected = Language.guess(from: name) ?? "tr"
        let fileURL = store(decoded.text, language: detected, format: document.format)
        let loaded = Loaded(document: document, name: name, language: detected, source: .turkcealtyazi, fileURL: fileURL,
                            encodingName: decoded.encodingName, repairNote: decoded.repairNote, score: nil, rawText: decoded.text)
        apply(loaded, resetTiming: true)
        phase = .finished
        return loaded
    }

    /// Sürükle-bırak ya da "Dosyadan ekle".
    @discardableResult
    func loadUserFile(_ url: URL) -> Bool {
        do {
            let loaded = try loadFile(url, source: .file, name: url.lastPathComponent, language: Language.guess(from: url.lastPathComponent) ?? language)
            apply(loaded, resetTiming: true)
            phase = .finished
            return true
        } catch {
            lastError = "Bu dosya okunamadı"
            return false
        }
    }

    /// Odadan gelen altyazı (ekran 15).
    func loadShared(text: String, name: String, language: String?, timing: SubtitleTiming) -> Bool {
        guard let decoded = SubtitleTextDecoder.decode(Data(text.utf8)), let document = try? SubtitleParser.parse(decoded.text) else { return false }
        apply(Loaded(document: document, name: name, language: language, source: .room, fileURL: nil, encodingName: "UTF-8", repairNote: nil, score: nil, rawText: decoded.text), resetTiming: false)
        self.timing = timing
        return true
    }

    func loadSecondary(_ url: URL) {
        secondary = try? loadFile(url, source: .file, name: url.lastPathComponent, language: Language.guess(from: url.lastPathComponent))
    }

    func clearSecondary() { secondary = nil }

    func selectEmbedded(_ track: MediaTrack) {
        loaded = nil
        embeddedTrackID = track.id
        enabled = true
        embeddedTask?.cancel()
        if let document = embeddedCache[track.id] {
            embeddedDocument = document
            player?.selectEmbeddedSubtitle(-1)
        } else {
            embeddedDocument = nil
            player?.selectEmbeddedSubtitle(-1)
            loadEmbedded(track)
        }
        applyTiming()
        onPersist?()
        onSubtitleReplaced?(.embedded)
    }

    /// Metin parçasını dosyadan okur. Okuma uzarsa (dizinsiz dosya, yavaş disk) arada VLC çizer.
    private func loadEmbedded(_ track: MediaTrack) {
        guard let extractor, !track.isImageSubtitle, let player else {
            player?.selectEmbeddedSubtitle(track.id)
            return
        }
        let order = player.embeddedSubtitles.map { (id: $0.id, language: $0.languageCode) }
        embeddedTask = Task { @MainActor [weak self] in
            let fallback = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(1500))
                guard !Task.isCancelled, let self, self.embeddedTrackID == track.id, self.embeddedDocument == nil, self.enabled else { return }
                self.player?.selectEmbeddedSubtitle(track.id)
            }
            defer { fallback.cancel() }
            let document = await extractor.document(forVLCTrack: track.id, order: order)
            guard !Task.isCancelled, let self, self.embeddedTrackID == track.id else { return }
            guard let document else {
                if self.enabled { self.player?.selectEmbeddedSubtitle(track.id) }
                return
            }
            self.embeddedCache[track.id] = document
            self.embeddedDocument = document
            self.player?.selectEmbeddedSubtitle(-1)
            self.applyTiming()
        }
    }

    func turnOff() {
        enabled = false
        if embeddedTrackID != nil { player?.selectEmbeddedSubtitle(-1) }
        onPersist?()
    }

    func turnOn() {
        enabled = true
        if let embeddedTrackID, embeddedDocument == nil { player?.selectEmbeddedSubtitle(embeddedTrackID) }
        onPersist?()
    }

    private func apply(_ loaded: Loaded, resetTiming: Bool) {
        if embeddedTrackID != nil { player?.selectEmbeddedSubtitle(-1) }
        embeddedTask?.cancel()
        embeddedTrackID = nil
        embeddedDocument = nil
        self.loaded = loaded
        enabled = true
        if resetTiming { timing = .identity }
        onPersist?()
        onSubtitleReplaced?(loaded.source)
    }

    private func loadFile(_ url: URL, source: Source, name: String?, language: String?) throws -> Loaded {
        let (document, decoded) = try Self.read(url)
        return Loaded(document: document, name: name ?? url.lastPathComponent, language: language, source: source,
                      fileURL: url, encodingName: decoded.encodingName, repairNote: decoded.repairNote, score: nil, rawText: decoded.text)
    }

    static func read(_ url: URL) throws -> (SubtitleDocument, SubtitleTextDecoder.Result) {
        try parse(try Data(contentsOf: url))
    }

    static func parse(_ data: Data) throws -> (SubtitleDocument, SubtitleTextDecoder.Result) {
        let preference = SubtitleTextDecoder.Preference(rawValue: UserDefaults.standard.string(forKey: SettingsKey.subtitleEncoding) ?? "auto") ?? .auto
        guard let decoded = SubtitleTextDecoder.decode(data, preference: preference) else { throw SubtitleParser.ParseError.unknownFormat }
        return (try SubtitleParser.parse(decoded.text), decoded)
    }

    // MARK: Önizleme

    /// Sonuç satırı seçilince indirilip hafızada ayrıştırılır ama oynatıcıya yüklenmez.
    @MainActor
    func preview(_ candidate: Candidate) async {
        guard previews[candidate.id] == nil else { return }
        if let url = candidate.localURL, let (document, _) = try? Self.read(url) {
            previews[candidate.id] = document
        }
        // İnternet adaylarını önizleme için indirmek günlük kotayı tüketir; yalnızca yerel önizleme.
    }

    // MARK: Görünen satırlar

    func visibleCues(at time: Double) -> [SubtitleCue] {
        guard enabled, let document = activeDocument else { return [] }
        return document.cues(at: time, timing: timing)
    }

    func visibleSecondaryCues(at time: Double) -> [SubtitleCue] {
        guard enabled, let secondary else { return [] }
        return secondary.document.cues(at: time, timing: .identity)
    }

    // MARK: Senkron

    /// G / H: ±100 ms. Görüntüde daha geç = pozitif.
    func nudge(by milliseconds: Int) {
        timing.offset += Double(milliseconds) / 1000
        syncAnchor = nil
    }

    func setOffset(milliseconds: Int) {
        timing.offset = Double(milliseconds) / 1000
    }

    func resetTiming() {
        timing = .identity
        syncAnchor = nil
    }

    /// "Duy ve bas": konuşmayı duyduğun an Space. Ekranda o ana en yakın başlayan satır o ana çekilir.
    /// İkinci işaret noktasında ölçek de hesaplanır: t' = a·t + b. Aradaki kayma satır aralığından
    /// büyük olabileceği için ikinci noktada yaygın FPS oranları denenip en iyi eşleşen satır seçilir.
    @discardableResult
    func markSpeech(at displayTime: Double) -> Bool {
        guard let cues = activeDocument?.cues, !cues.isEmpty else { return false }

        if let anchor = syncAnchor, abs(displayTime - anchor.display) > 60 {
            let ratios = [1, 25 / 23.976, 23.976 / 25, 24 / 25.0, 25 / 24.0, 24 / 23.976, 23.976 / 24]
            var best: (cue: SubtitleCue, distance: Double)?
            for ratio in ratios {
                let offset = anchor.display - ratio * anchor.source
                let source = (displayTime - offset) / ratio
                guard let cue = Self.nearest(in: cues, to: source) else { continue }
                let distance = abs(cue.start - source)
                if best == nil || distance < best!.distance { best = (cue, distance) }
            }
            if let cue = best?.cue, cue.start != anchor.source {
                let scale = (displayTime - anchor.display) / (cue.start - anchor.source)
                if (0.9...1.1).contains(scale) {
                    timing = SubtitleTiming(scale: scale, offset: anchor.display - scale * anchor.source)
                    syncAnchor = (cue.start, displayTime)
                    return true
                }
            }
        }

        // Tek nokta: şu an görünen ya da en yakın başlayan satır.
        let source = timing.sourceTime(for: displayTime)
        guard let cue = Self.nearest(in: cues, to: source) else { return false }
        timing.offset = displayTime - timing.scale * cue.start
        syncAnchor = (cue.start, displayTime)
        return true
    }

    /// Başlangıcı `time`'a en yakın satır (ikili arama).
    private static func nearest(in cues: [SubtitleCue], to time: Double) -> SubtitleCue? {
        var low = 0, high = cues.count
        while low < high {
            let mid = (low + high) / 2
            if cues[mid].start < time { low = mid + 1 } else { high = mid }
        }
        let candidates = [low - 1, low].filter { $0 >= 0 && $0 < cues.count }.map { cues[$0] }
        return candidates.min { abs($0.start - time) < abs($1.start - time) }
    }

    private func applyTiming() {
        if embeddedTrackID != nil { player?.setEmbeddedSubtitleDelay(embeddedRenderedByVLC ? timing.offsetMilliseconds : 0) }
        onPersist?()
        onTimingChanged?(timing)
    }

    // MARK: Yardımcılar

    @MainActor
    private func waitForTracks() async -> Bool {
        for _ in 0..<30 {
            if Task.isCancelled { return false }
            if let player, player.tracksRevision > 0 { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    private func setStatus(_ id: String, _ status: SourceStatus.Status) {
        if let index = sources.firstIndex(where: { $0.id == id }) { sources[index].status = status }
    }

    private func skipRemaining() {
        sources = sources.map { $0.status == .waiting ? SourceStatus(id: $0.id, status: .skipped("gerek yok")) : $0 }
    }

    /// Aynı klasörde <ad>.tr.srt, <ad>.srt, <ad>.ass…
    func findSidecars() -> [Candidate] {
        guard let mediaURL else { return [] }
        let folder = mediaURL.deletingLastPathComponent()
        let base = mediaURL.deletingPathExtension().lastPathComponent.lowercased()
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { url -> Candidate? in
            guard AppInfo.subtitleExtensions.contains(url.pathExtension.lowercased()) else { return nil }
            let name = url.deletingPathExtension().lastPathComponent.lowercased()
            guard name.hasPrefix(base) || base.hasPrefix(name) else { return nil }
            let suffix = String(name.dropFirst(min(base.count, name.count)))
            let language = Language.guess(from: suffix.replacingOccurrences(of: ".", with: " ")) ?? Language.guess(from: name.replacingOccurrences(of: ".", with: " ")) ?? self.language
            return Candidate(
                id: url.path, name: url.lastPathComponent, language: language, source: .sidecar,
                score: name == base || suffix.count <= 4 ? 95 : 80, hashMatch: false, releaseMatch: true, fpsMismatch: false,
                fps: nil, downloads: 0, fileID: nil, localURL: url
            )
        }
    }

    private func makeCandidate(_ result: OpenSubtitlesClient.Result) -> Candidate {
        let release = ParsedFilename(filename: result.release + ".x").release
        let releaseMatch = release != nil && release == parsedName.release
        let videoFPS = player?.videoTrack?.frameRate
        let fpsMismatch = result.fps.flatMap { fps in videoFPS.map { abs($0 - fps) > 0.05 } } ?? false
        var score: Int
        if result.hashMatch {
            score = 98 + (result.fromTrusted ? 1 : 0)
        } else {
            score = 50
            if releaseMatch { score += 25 }
            if let fps = result.fps, let videoFPS, abs(fps - videoFPS) <= 0.05 { score += 10 }
            if fpsMismatch { score -= 5 }
            score += min(10, Int(log10(Double(max(result.downloads, 1))) * 2.5))
            score += Int(min(result.rating, 10) / 2)
            score = min(score, 95)
        }
        return Candidate(
            id: "os-\(result.fileID)", name: result.release.isEmpty ? result.fileName : result.release,
            language: result.language, source: .openSubtitles, score: score, hashMatch: result.hashMatch,
            releaseMatch: releaseMatch, fpsMismatch: fpsMismatch, fps: result.fps, downloads: result.downloads,
            fileID: result.fileID, localURL: nil
        )
    }

    private func makeSubdlCandidate(_ result: SubdlClient.Result) -> Candidate {
        let release = ParsedFilename(filename: result.releaseName + ".x").release
        let releaseMatch = release != nil && release == parsedName.release
        let videoFPS = player?.videoTrack?.frameRate
        let fpsMismatch = result.fps.flatMap { fps in videoFPS.map { abs($0 - fps) > 0.05 } } ?? false
        // Dosya kimliğiyle eşleşme yok: en fazla %90 (OpenSubtitles hash eşleşmesinin altında kalır).
        // Ad + yıl eşleşmesi tek başına otomatik açmaya yeter (≥ %60); sürüm uyumu öne çıkarır.
        var score = 60
        if releaseMatch { score += 25 }
        if let fps = result.fps, let videoFPS, abs(fps - videoFPS) <= 0.05 { score += 10 }
        if fpsMismatch { score -= 5 }
        if result.hearingImpaired { score -= 3 }
        if result.fullSeason { score -= 5 }
        return Candidate(
            id: "subdl-\(result.path)", name: result.releaseName.isEmpty ? result.path : result.releaseName,
            language: result.language, source: .subdl, score: min(score, 90), hashMatch: false,
            releaseMatch: releaseMatch, fpsMismatch: fpsMismatch, fps: result.fps, downloads: 0,
            fileID: nil, localURL: nil, downloadPath: result.path
        )
    }

    private static func ranking(languages: [String]) -> (Candidate, Candidate) -> Bool {
        { lhs, rhs in
            let left = languages.firstIndex(of: lhs.language) ?? languages.count
            let right = languages.firstIndex(of: rhs.language) ?? languages.count
            if left != right { return left < right }
            return lhs.score > rhs.score
        }
    }
}

/// Gömülü metin altyazıları arka planda okur; VLC parça kimliğini MKV parça numarasıyla eşler.
actor EmbeddedSubtitleExtractor {
    let url: URL
    private var reader: MatroskaSubtitleReader?
    private var failed = false

    init(url: URL) { self.url = url }

    /// `order`: VLC'nin altyazı parçaları (kimlik, dil) listelediği sırayla; bu, dosyadaki sırayla aynıdır.
    func document(forVLCTrack id: Int32, order: [(id: Int32, language: String?)]) -> SubtitleDocument? {
        guard let reader = openReader(), let index = order.firstIndex(where: { $0.id == id }) else { return nil }
        let tracks = reader.tracks
        let language = order[index].language
        let track: MatroskaSubtitleReader.Track?
        if tracks.count == order.count {
            track = tracks[index]
        } else if let language {
            // Sayılar tutmuyorsa aynı dildeki parçalar arasında aynı sıradaki.
            let before = order[..<index].filter { $0.language == language }.count
            track = tracks.filter { Self.code($0.language) == language }.dropFirst(before).first
        } else {
            track = nil
        }
        guard let track, track.isText else { return nil }
        if let language, let own = Self.code(track.language), own != language { return nil }
        guard let cues = try? reader.cues(for: track.number), !cues.isEmpty else { return nil }
        return SubtitleDocument(cues: cues, format: track.codecID.contains("ASS") || track.codecID.contains("SSA") ? .ass : .srt)
    }

    private static func code(_ language: String?) -> String? {
        Language.short(for: language)?.lowercased()
    }

    private func openReader() -> MatroskaSubtitleReader? {
        if let reader { return reader }
        guard !failed else { return nil }
        do {
            reader = try MatroskaSubtitleReader(url: url)
        } catch {
            failed = true
        }
        return reader
    }
}
