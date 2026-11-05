import Foundation
import AppKit
import QuartzCore
import Observation
import VLCKit

/// Oynatma servisi: VLCKit'in `VLCMediaPlayer`'ını sarar. Arayüz libVLC'ye doğrudan dokunmaz;
/// her şey bu sınıfın durumundan ve metotlarından geçer (spesifikasyon › Teknik mimari).
@Observable
final class PlayerController: NSObject {
    enum State: Equatable {
        case idle, opening, buffering, playing, paused, ended
        case error(String)

        var isError: Bool {
            if case .error = self { return true }
            return false
        }
    }

    struct Chapter: Identifiable, Equatable {
        let id: Int
        let name: String
        let start: Double
        let duration: Double
    }

    // MARK: Durum

    private(set) var url: URL?
    private(set) var state: State = .idle
    private(set) var isPlaying = false
    /// Saniye.
    private(set) var time: Double = 0
    private(set) var duration: Double = 0
    private(set) var rate: Float = 1
    private(set) var volume: Int = 80
    private(set) var muted = false
    private(set) var audioTracks: [MediaTrack] = []
    private(set) var embeddedSubtitles: [MediaTrack] = []
    private(set) var videoTrack: MediaTrack?
    private(set) var currentAudioID: Int32 = -1
    private(set) var currentEmbeddedSubtitleID: Int32 = -1
    private(set) var chapters: [Chapter] = []
    private(set) var videoSize: CGSize = .zero
    /// Ses gecikmesi (ms).
    private(set) var audioDelay: Int = 0
    /// Gömülü (VLC'nin çizdiği) altyazının gecikmesi (ms).
    private(set) var embeddedSubtitleDelay: Int = 0
    /// Bu dosyadan ilk kare geldi mi (önceki dosyanın son karesi görünmesin diye).
    private(set) var hasVideoFrame = false
    /// Oynatma en az bir kez başladı mı (açılamayan dosyayı ayırt etmek için).
    private(set) var hasStarted = false
    /// Parça listesi ilk kez dolduğunda artar (altyazı servisinin gömülü parça aramasını tetikler).
    private(set) var tracksRevision = 0

    /// Sarma sürerken çubuk eski zamana geri sıçramasın diye hedef zaman.
    private var pendingSeek: Double?
    private var pendingSeekDate: Date?

    /// Son zaman bildirimi (ara değerleme için): VLC zamanı ~250 ms'de bir bildirir.
    @ObservationIgnored private var lastReport: (time: Double, at: CFTimeInterval)?
    /// Yeni dosya "açılıyor" olayını verene kadar gelen zaman olayları önceki dosyadan kalmadır.
    @ObservationIgnored private var awaitingOpen = false
    /// 50+ parçalı dosyalarda her "parça eklendi" olayında listeyi yeniden kurmamak için.
    @ObservationIgnored private var tracksRefreshScheduled = false
    @ObservationIgnored private var lastTrackCheck: CFTimeInterval = 0
    /// libVLC örneği ilk kullanımda oluşur (~50 ms); açılışta pencere çizildikten sonra `warmUp()` ile ısıtılır.
    @ObservationIgnored lazy var mediaPlayer: VLCMediaPlayer = {
        var options = [
            "--no-video-title-show",   // dosya adını görüntüye yazma
            "--no-sub-autodetect-file", // yanındaki .srt'yi altyazı servisi yönetir
            "--no-osd",
            "--no-snapshot-preview",
        ]
        // Gömülü metin altyazıları biz çizeriz; VLC yalnızca okuyamadıklarımızı (MP4 metin, dizinsiz yavaş
        // dosyalar) çizer. Onlar da en azından boyut ve renk tercihine uysun.
        let scale = UserDefaults.standard.integer(forKey: SettingsKey.embeddedSubtitleScale)
        if scale > 0 { options.append("--sub-text-scale=\(scale)") }
        options.append("--freetype-color=\(SubtitleStyleStore.shared.style.color.rgb)")
        let player = VLCMediaPlayer(options: options)
        player.delegate = self
        #if DEBUG
        // Teşhis: KD_VLC_LOG=1 libVLC günlüğünü stderr'e yazar.
        if ProcessInfo.processInfo.environment["KD_VLC_LOG"] != nil {
            let logger = VLCConsoleLogger()
            logger.level = .debug
            player.libraryInstance.loggers = [logger]
        }
        #endif
        return player
    }()
    @ObservationIgnored var onEnded: (() -> Void)?
    @ObservationIgnored var onTimeChanged: ((Double) -> Void)?
    @ObservationIgnored var onStateChanged: ((State) -> Void)?

    override init() {
        super.init()
        volume = UserDefaults.standard.object(forKey: SettingsKey.volume) as? Int ?? 80
    }

    /// libVLC'yi önceden oluşturur (ilk dosya açılışı beklemesin).
    func warmUp() {
        _ = mediaPlayer
    }

    // MARK: Açma

    func open(_ url: URL, startAt seconds: Double? = nil) {
        stop()
        #if DEBUG
        PerfTimeline.mark("vlc.stopped")
        #endif
        self.url = url
        state = .opening
        time = seconds ?? 0
        duration = 0
        audioTracks = []
        embeddedSubtitles = []
        currentEmbeddedSubtitleID = -1
        currentAudioID = -1
        chapters = []
        videoTrack = nil
        videoSize = .zero
        hasVideoFrame = false
        hasStarted = false
        awaitingOpen = true
        lastReport = nil
        audioDelay = 0
        embeddedSubtitleDelay = 0
        rate = 1

        let media = VLCMedia(url: url)
        if !UserDefaults.standard.bool(forKey: SettingsKey.hardwareDecodingDisabled) {
            media.addOption(":avcodec-hw=any")
        } else {
            media.addOption(":avcodec-hw=none")
        }
        if let seconds, seconds > 1 {
            media.addOption(":start-time=\(seconds)")
        }
        // Yerel dosyada VLC varsayılan 1000 ms önbellek doldurur; 300 ms açılışı ve sarmayı hızlandırır.
        media.addOption(url.isFileURL ? ":file-caching=300" : ":network-caching=1000")
        mediaPlayer.media = media
        mediaPlayer.rate = 1
        applyVolume()
        mediaPlayer.play()
    }

    func stop() {
        guard url != nil, mediaPlayer.media != nil else { return }
        mediaPlayer.stop()
        isPlaying = false
        state = .idle
    }

    // MARK: Oynatma

    func play() {
        if state == .ended, let url {
            open(url)
            return
        }
        mediaPlayer.play()
    }

    func pause() {
        if mediaPlayer.canPause { mediaPlayer.pause() }
    }

    func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    func seek(to seconds: Double) {
        let target = duration > 0 ? seconds.clamped(to: 0...max(0, duration - 0.5)) : max(0, seconds)
        pendingSeek = target
        pendingSeekDate = .now
        time = target
        mediaPlayer.time = VLCTime(int: Int32(target * 1000))
    }

    func seek(by delta: Double) {
        seek(to: (pendingSeek ?? time) + delta)
    }

    /// Kare kare ilerleme (duraklatılmışken). VLC 3 geri kare desteklemediği için geri ≈ 1 kare sarma.
    func step(forward: Bool) {
        if isPlaying { pause() }
        if forward {
            mediaPlayer.gotoNextFrame()
        } else {
            let fps = videoTrack?.frameRate ?? 24
            seek(by: -1 / max(fps, 1))
        }
    }

    func setRate(_ value: Float) {
        let clamped = min(max(value, 0.25), 4)
        rate = clamped
        mediaPlayer.rate = clamped
    }

    /// Oda sapma düzeltmesi: hızı geçici olarak ×0,97 / ×1,03 yapar; görünen hız değişmez.
    func setRateNudge(_ factor: Float) {
        mediaPlayer.rate = rate * factor
    }

    func setVolume(_ value: Int) {
        volume = value.clamped(to: 0...100)
        if muted && volume > 0 { muted = false }
        UserDefaults.standard.set(volume, forKey: SettingsKey.volume)
        applyVolume()
    }

    func toggleMute() {
        muted.toggle()
        applyVolume()
    }

    /// Kullanıcının ses ayarına dokunmadan geçici sessizlik (devam et kartı arkasında ilk kare çözülürken).
    var silenced = false {
        didSet { applyVolume() }
    }

    private func applyVolume() {
        mediaPlayer.audio?.volume = Int32(muted || silenced ? 0 : volume)
    }

    func setAudioDelay(_ ms: Int) {
        audioDelay = ms
        mediaPlayer.currentAudioPlaybackDelay = ms * 1000
    }

    func setEmbeddedSubtitleDelay(_ ms: Int) {
        embeddedSubtitleDelay = ms
        mediaPlayer.currentVideoSubTitleDelay = ms * 1000
    }

    // MARK: Parçalar

    func selectAudio(_ id: Int32) {
        mediaPlayer.currentAudioTrackIndex = id
        currentAudioID = id
    }

    /// Gömülü altyazıyı VLC çizer; -1 kapatır (harici altyazıyı biz çizeriz).
    func selectEmbeddedSubtitle(_ id: Int32) {
        mediaPlayer.currentVideoSubTitleIndex = id
        currentEmbeddedSubtitleID = id
    }

    /// Bir sonraki çalınabilir ses parçasına geç (A kısayolu).
    @discardableResult
    func cycleAudio() -> MediaTrack? {
        let playable = audioTracks.filter { !$0.isUnsupported }
        guard !playable.isEmpty else { return nil }
        let index = playable.firstIndex { $0.id == currentAudioID } ?? -1
        let next = playable[(index + 1) % playable.count]
        selectAudio(next.id)
        return next
    }

    func goToChapter(_ chapter: Chapter) {
        seek(to: chapter.start)
    }

    func chapter(at seconds: Double) -> Chapter? {
        chapters.last { $0.start <= seconds }
    }

    /// Küçük resim için anlık görüntü (İzlemeye devam et listesi).
    func saveSnapshot(to url: URL, width: Int32 = 320) {
        guard mediaPlayer.hasVideoOut else { return }
        mediaPlayer.saveVideoSnapshot(at: url.path, withWidth: width, andHeight: 0)
    }

    /// Bildirimler arasında ara değerlenmiş konum (oda senkronu için ms hassasiyetinde).
    var preciseTime: Double {
        guard isPlaying, pendingSeek == nil, let report = lastReport else { return pendingSeek ?? time }
        let elapsed = CACurrentMediaTime() - report.at
        guard elapsed < 1.5 else { return time }
        return report.time + elapsed * Double(mediaPlayer.rate)
    }

    var remaining: Double { max(0, duration - time) }
    var progress: Double { duration > 0 ? time / duration : 0 }

    // MARK: Parça bilgisi

    /// Remux'larda her parça başlığında tekrar eden sürüm grubu etiketi ("BTM SDH", "BTM DD 5.1 LA") atılır.
    private static func stripCommonTag(_ audio: inout [MediaTrack], _ subtitles: inout [MediaTrack]) {
        let all = audio + subtitles
        guard all.count >= 4 else { return }
        let firstWords = all.compactMap { $0.trackDescription?.split(separator: " ").first.map(String.init) }
        guard let tag = Dictionary(grouping: firstWords, by: { $0 }).max(by: { $0.value.count < $1.value.count })?.key,
              Double(firstWords.filter { $0 == tag }.count) >= Double(all.count) * 0.7, Language.guess(from: tag) == nil else { return }
        func strip(_ track: inout MediaTrack) {
            guard let description = track.trackDescription, description.hasPrefix(tag) else { return }
            let rest = description.dropFirst(tag.count).trimmingCharacters(in: .whitespaces)
            track.trackDescription = rest.isEmpty ? nil : rest
        }
        for index in audio.indices { strip(&audio[index]) }
        for index in subtitles.indices { strip(&subtitles[index]) }
    }

    private func scheduleTrackRefresh() {
        guard !tracksRefreshScheduled else { return }
        tracksRefreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.tracksRefreshScheduled = false
            self.refreshTracks()
        }
    }

    /// VLC parçaları açılıştan sonra seçer (varsayılan ses, "default" işaretli altyazı): saniyede bir
    /// eşitlenir. Ses VLC'nin seçimine uyar; altyazıyı ise altyazı servisi belirler, VLC kendi başına
    /// (iri ve stilsiz) bir parça açmasın.
    private func syncSelectedTracks() {
        let now = CACurrentMediaTime()
        guard now - lastTrackCheck > 1 else { return }
        lastTrackCheck = now
        let audio = mediaPlayer.currentAudioTrackIndex
        if audio != currentAudioID { currentAudioID = audio }
        if mediaPlayer.currentVideoSubTitleIndex != currentEmbeddedSubtitleID {
            mediaPlayer.currentVideoSubTitleIndex = currentEmbeddedSubtitleID
        }
    }

    private func refreshTracks() {
        guard let media = mediaPlayer.media else { return }
        let infos = (media.tracksInformation as? [[String: Any]]) ?? []

        let audioIDs = (mediaPlayer.audioTrackIndexes as? [NSNumber])?.map(\.int32Value) ?? []
        let audioNames = (mediaPlayer.audioTrackNames as? [String]) ?? []
        audioTracks = zip(audioIDs, audioNames).compactMap { id, name in
            guard id >= 0 else { return nil }
            return MediaTrack(id: id, kind: .audio, vlcName: name, info: infos.first { ($0[VLCMediaTracksInformationId] as? NSNumber)?.int32Value == id })
        }

        let subIDs = (mediaPlayer.videoSubTitlesIndexes as? [NSNumber])?.map(\.int32Value) ?? []
        let subNames = (mediaPlayer.videoSubTitlesNames as? [String]) ?? []
        embeddedSubtitles = zip(subIDs, subNames).compactMap { id, name in
            guard id >= 0 else { return nil }
            return MediaTrack(id: id, kind: .subtitle, vlcName: name, info: infos.first { ($0[VLCMediaTracksInformationId] as? NSNumber)?.int32Value == id })
        }

        Self.stripCommonTag(&audioTracks, &embeddedSubtitles)

        if let info = infos.first(where: { ($0[VLCMediaTracksInformationType] as? String) == VLCMediaTracksInformationTypeVideo }) {
            videoTrack = MediaTrack(id: -1, kind: .video, vlcName: "", info: info)
        }
        currentAudioID = mediaPlayer.currentAudioTrackIndex
        // Altyazı seçimi altyazı servisinin: VLC'nin "default" parçayı kendiliğinden açması benimsenmez.
        if currentEmbeddedSubtitleID >= 0, !embeddedSubtitles.contains(where: { $0.id == currentEmbeddedSubtitleID }) {
            currentEmbeddedSubtitleID = -1
        }
        if mediaPlayer.currentVideoSubTitleIndex != currentEmbeddedSubtitleID {
            mediaPlayer.currentVideoSubTitleIndex = currentEmbeddedSubtitleID
        }
        videoSize = mediaPlayer.videoSize

        let descriptions = (mediaPlayer.chapterDescriptions(ofTitle: mediaPlayer.currentTitleIndex) as? [[String: Any]]) ?? []
        chapters = descriptions.enumerated().map { index, entry in
            Chapter(
                id: index,
                name: (entry[VLCChapterDescriptionName] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Bölüm \(index + 1)",
                start: ((entry[VLCChapterDescriptionTimeOffset] as? NSNumber)?.doubleValue ?? 0) / 1000,
                duration: ((entry[VLCChapterDescriptionDuration] as? NSNumber)?.doubleValue ?? 0) / 1000
            )
        }
        tracksRevision += 1
    }

    private func updateDuration() {
        if let length = mediaPlayer.media?.length.value?.doubleValue, length > 0 {
            duration = length / 1000
        }
    }
}

// MARK: - VLCMediaPlayerDelegate (ana iş parçacığında çağrılır)

extension PlayerController: VLCMediaPlayerDelegate {
    func mediaPlayerStateChanged(_ notification: Notification) {
        let previous = state
        switch mediaPlayer.state {
        case .opening:
            awaitingOpen = false
            state = .opening
            #if DEBUG
            PerfTimeline.mark("vlc.opening")
            #endif
        case .buffering:
            if !mediaPlayer.isPlaying && state != .paused { state = .buffering }
        case .playing:
            state = .playing
            #if DEBUG
            PerfTimeline.mark("vlc.playing")
            #endif
        case .paused:
            state = .paused
        case .ended:
            state = .ended
        case .stopped:
            if state != .ended && !state.isError { state = .idle }
        case .error:
            state = .error(VLCLibrary.currentErrorMessage ?? "Dosya açılamadı")
        case .esAdded:
            scheduleTrackRefresh()
        @unknown default:
            break
        }
        isPlaying = mediaPlayer.isPlaying
        // Yeni dosyanın video çıkışı oluştu: duraklatılmış ilk kare de görünsün.
        if !hasVideoFrame, mediaPlayer.hasVideoOut, state == .playing || state == .paused {
            hasVideoFrame = true
            #if DEBUG
            PerfTimeline.mark("vlc.firstFrame")
            #endif
        }
        if state == .playing, audioTracks.isEmpty && embeddedSubtitles.isEmpty {
            refreshTracks()
        }
        updateDuration()
        if state != previous {
            onStateChanged?(state)
            if state == .ended { onEnded?() }
        }
    }

    func mediaPlayerTimeChanged(_ notification: Notification) {
        // Kuyrukta bekleyen, önceki dosyaya ait olay (VLCKit son zamanı önbellekten verir).
        guard !awaitingOpen else { return }
        let reported = Double(mediaPlayer.time.intValue) / 1000
        if let pendingSeek, let date = pendingSeekDate {
            // VLC sarmayı uygulayana kadar eski zamanı raporlayabilir.
            if abs(reported - pendingSeek) < 1.5 || Date.now.timeIntervalSince(date) > 1.5 {
                self.pendingSeek = nil
                self.pendingSeekDate = nil
                time = reported
                lastReport = (reported, CACurrentMediaTime())
            }
        } else {
            time = reported
            lastReport = (reported, CACurrentMediaTime())
        }
        if duration <= 0 { updateDuration() }
        if !isPlaying && mediaPlayer.isPlaying { isPlaying = true }
        if videoSize == .zero, mediaPlayer.hasVideoOut { videoSize = mediaPlayer.videoSize }
        if !hasVideoFrame, mediaPlayer.hasVideoOut, reported > 0 {
            hasVideoFrame = true
            #if DEBUG
            PerfTimeline.mark("vlc.firstFrame")
            #endif
        }
        if !hasStarted, reported > 0 { hasStarted = true }
        syncSelectedTracks()
        onTimeChanged?(time)
    }
}

// MARK: - Parça modeli

struct MediaTrack: Identifiable, Equatable {
    enum Kind { case audio, subtitle, video }

    let id: Int32
    let kind: Kind
    let vlcName: String
    var language: String?
    var codec: String?
    var channels: Int?
    var bitrate: Int?
    var trackDescription: String?
    var frameRate: Double?
    var width: Int?
    var height: Int?

    init(id: Int32, kind: Kind, vlcName: String, info: [String: Any]?) {
        self.id = id
        self.kind = kind
        self.vlcName = vlcName
        if let info {
            language = (info[VLCMediaTracksInformationLanguage] as? String).flatMap { $0.isEmpty || Language.undefined.contains($0.lowercased()) ? nil : Language.code(for: $0) }
            if let fourcc = (info[VLCMediaTracksInformationCodec] as? NSNumber)?.uint32Value {
                codec = MediaTrack.fourCC(fourcc)
            }
            channels = (info[VLCMediaTracksInformationAudioChannelsNumber] as? NSNumber)?.intValue
            bitrate = (info[VLCMediaTracksInformationBitrate] as? NSNumber)?.intValue
            trackDescription = (info[VLCMediaTracksInformationDescription] as? String).flatMap { $0.isEmpty ? nil : $0 }
            if let numerator = (info[VLCMediaTracksInformationFrameRate] as? NSNumber)?.doubleValue,
               let denominator = (info[VLCMediaTracksInformationFrameRateDenominator] as? NSNumber)?.doubleValue, denominator > 0 {
                frameRate = numerator / denominator
            }
            width = (info[VLCMediaTracksInformationVideoWidth] as? NSNumber)?.intValue
            height = (info[VLCMediaTracksInformationVideoHeight] as? NSNumber)?.intValue
        }
        if language == nil { language = Language.guess(from: vlcName) }
    }

    /// Dil kodu (2 harf, varsa).
    var languageCode: String? { Language.short(for: language)?.lowercased() }

    var languageName: String {
        Language.name(for: language) ?? cleanedName
    }

    /// VLC'nin "Track 1 - [English]" biçimindeki adından okunaklı kısım.
    var cleanedName: String {
        var name = vlcName
        if let range = name.range(of: #"^(Track|Parça|Piste)\s*\d+\s*-?\s*"#, options: .regularExpression) {
            name.removeSubrange(range)
        }
        // "BTM DD 5.1 - [English]" → "BTM DD 5.1"
        if let range = name.range(of: #"\s*-?\s*\[[^\]]*\]\s*$"#, options: .regularExpression), range.lowerBound > name.startIndex {
            name.removeSubrange(range)
        }
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: "[] -"))
        return name.isEmpty ? "Parça \(id)" : name
    }

    var isForced: Bool {
        let text = (vlcName + " " + (trackDescription ?? "")).lowercased(with: Format.turkish)
        return text.contains("forced") || text.contains("zorunlu")
    }

    var isCommentary: Bool {
        let text = (vlcName + " " + (trackDescription ?? "")).lowercased(with: Format.turkish)
        return text.contains("comment") || text.contains("yorum")
    }

    var isDub: Bool {
        let text = (vlcName + " " + (trackDescription ?? "")).lowercased(with: Format.turkish)
        return text.contains("dub")
    }

    /// Görüntü tabanlı altyazı (PGS / VobSub / DVB): stil uygulanamaz.
    var isImageSubtitle: Bool {
        guard let codec else { return false }
        return ["PGS", "VobSub", "DVB"].contains(codec)
    }

    /// Gömülü VLCKit'in çözemediği ses codec'i. VideoLAN'ın hazır VLCKit paketinde FFmpeg TrueHD/MLP'siz
    /// derlenir ("codec not found (TrueHD Audio)"); `scripts/build-vlckit.sh` ile derlenen pakette çözücü vardır.
    var isUnsupported: Bool { kind == .audio && codec == "TrueHD" && !CodecSupport.trueHD }

    var channelLabel: String? {
        guard let channels, channels > 0 else { return nil }
        switch channels {
        case 1: return "Mono"
        case 2: return "Stereo"
        case 6: return "5.1"
        case 8: return "7.1"
        default: return "\(channels) kanal"
        }
    }

    /// "5.1 · DTS · 640 kbps" / "Metin (SRT) · stili değiştirilebilir".
    var meta: String {
        switch kind {
        case .audio:
            var parts: [String] = []
            if let channelLabel { parts.append(channelLabel) }
            if let codec { parts.append(codec) }
            if let bitrate, bitrate > 0 { parts.append("\(bitrate * 8 / 1000) kbps") }
            if let label = extraLabel { parts.append(label) }
            return parts.joined(separator: " · ")
        case .subtitle:
            var base: String
            if isForced {
                base = "Sadece yabancı dildeki konuşmalar"
            } else if isImageSubtitle {
                base = "Görüntü (\(codec ?? "PGS")) · stil değiştirilemez"
            } else {
                base = "Metin (\(codec ?? "SRT"))"
            }
            if let label = extraLabel { base += " · \(label)" }
            return base
        case .video:
            var parts: [String] = []
            if let height { parts.append("\(height)p") }
            if let codec { parts.append(codec) }
            return parts.joined(separator: " ")
        }
    }

    /// Parçanın kendi başlığı ("SDH", "LA", "Atmos"): aynı dildeki parçaları ayırt etmek için.
    /// Dil adını, codec'i ya da kanal düzenini tekrar eden kısımlar atılır.
    var extraLabel: String? {
        guard let raw = trackDescription?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        // Codec ve kanal bilgisi zaten yanında yazıyor: "DD 5.1 LA" → "LA", "TrueHD Atmos" → "Atmos".
        let noise: Set<String> = ["dd", "dd+", "ddp", "dd5.1", "ac3", "eac3", "e-ac3", "truehd", "dts", "dts-hd", "dts-x", "ma", "hra",
                                  "aac", "flac", "pcm", "lpcm", "opus", "mp3", "srt", "ass", "pgs", "sup", "subrip",
                                  "1.0", "2.0", "5.1", "6.1", "7.1", "stereo", "mono", "-", "·", "|"]
        let language = [languageName, language ?? "", Language.short(for: language) ?? ""].map { $0.lowercased(with: Format.turkish) }
        let words = raw.split(whereSeparator: \.isWhitespace).map(String.init).filter { word in
            let lower = word.lowercased(with: Format.turkish)
            return !noise.contains(lower) && !language.contains(lower) && lower != codec?.lowercased()
        }
        guard !words.isEmpty else { return nil }
        let label = words.joined(separator: " ")
        return label.count > 28 ? String(label.prefix(27)) + "…" : label
    }

    /// Ses parçası başlığı: "English · Orijinal", "Türkçe · Dublaj".
    var audioTitle: String {
        var title = languageName
        if isCommentary { title += " · Yorum" } else if isDub { title += " · Dublaj" }
        return title
    }

    static func fourCC(_ value: UInt32) -> String {
        let bytes = [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)]
        let raw = String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        let names: [String: String] = [
            "a52": "AC3", "eac3": "E-AC3", "dts": "DTS", "mp4a": "AAC", "mpga": "MP3", "mp3": "MP3",
            "mlp": "TrueHD", "trhd": "TrueHD", "flac": "FLAC", "opus": "Opus", "vorb": "Vorbis", "araw": "PCM", "lpcm": "PCM",
            "subt": "SRT", "ssa": "ASS", "tx3g": "TX3G", "webv": "WebVTT", "wvtt": "WebVTT",
            "pgs": "PGS", "pgss": "PGS", "spu": "VobSub", "spu ": "VobSub", "dvbs": "DVB",
            "h264": "H.264", "avc1": "H.264", "hevc": "HEVC", "h265": "HEVC", "av01": "AV1", "vp90": "VP9", "vp80": "VP8",
            "mp4v": "MPEG-4", "xvid": "XviD", "div3": "DivX", "mpgv": "MPEG-2",
        ]
        return names[raw] ?? raw.uppercased()
    }
}
