import Foundation

/// OpenSubtitles `moviehash`: dosya boyutu + ilk ve son 64 KB'ın 64 bit toplamı (16 hex hane).
/// Aynı zamanda yerel veride dosya kimliği olarak kullanılır (altyazı + offset dosya başına saklanır).
enum MovieHash {
    static let chunkSize = 65_536

    static func compute(for url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        var hash = size
        func add(_ data: Data) {
            data.withUnsafeBytes { buffer in
                let words = buffer.bindMemory(to: UInt64.self)
                for word in words { hash = hash &+ UInt64(littleEndian: word) }
            }
        }
        try handle.seek(toOffset: 0)
        add(handle.readData(ofLength: chunkSize))
        try handle.seek(toOffset: size > UInt64(chunkSize) ? size - UInt64(chunkSize) : 0)
        add(handle.readData(ofLength: chunkSize))
        return String(format: "%016llx", hash)
    }
}

/// Dosya adından başlık, yıl, sezon/bölüm ve release etiketi çıkarır.
/// "Son.Vapur.2025.1080p.WEB-DL.x265-GRP.mkv" → başlık "Son Vapur", yıl 2025, release "WEB-DL".
struct ParsedFilename: Equatable {
    var title: String
    var year: Int?
    var season: Int?
    var episode: Int?
    var release: String?
    var resolution: String?

    var isEpisode: Bool { season != nil && episode != nil }

    /// "S02E06"
    var episodeCode: String? {
        guard let season, let episode else { return nil }
        return String(format: "S%02dE%02d", season, episode)
    }

    /// Arama sorgusu: "Son Vapur 2025" / "Dizi S02E06".
    var query: String {
        if let episodeCode { return "\(title) \(episodeCode)" }
        if let year { return "\(title) \(year)" }
        return title
    }

    static let releaseTags: [(String, String)] = [
        ("web-dl", "WEB-DL"), ("webdl", "WEB-DL"), ("webrip", "WEBRip"), ("web", "WEB-DL"),
        ("bluray", "BluRay"), ("blu-ray", "BluRay"), ("bdrip", "BluRay"), ("brrip", "BluRay"), ("remux", "BluRay"),
        ("hdtv", "HDTV"), ("dvdrip", "DVDRip"), ("hdrip", "HDRip"), ("dvd", "DVDRip"),
    ]

    init(title: String, year: Int? = nil, season: Int? = nil, episode: Int? = nil, release: String? = nil, resolution: String? = nil) {
        self.title = title
        self.year = year
        self.season = season
        self.episode = episode
        self.release = release
        self.resolution = resolution
    }

    init(filename: String) {
        let base = (filename as NSString).deletingPathExtension
        let tokens = base
            .replacingOccurrences(of: #"[\[\]\(\)\{\}]"#, with: " ", options: .regularExpression)
            .split(whereSeparator: { $0 == "." || $0 == "_" || $0 == " " })
            .map(String.init)

        var titleTokens: [String] = []
        var year: Int?
        var season: Int?
        var episode: Int?
        var release: String?
        var resolution: String?
        var titleEnded = false

        for token in tokens {
            let lower = token.lowercased()
            if let match = lower.firstMatch(of: #/^s(\d{1,2})e(\d{1,3})/#) {
                season = Int(match.1); episode = Int(match.2); titleEnded = true; continue
            }
            if let match = lower.firstMatch(of: #/^(\d{1,2})x(\d{2,3})$/#) {
                season = Int(match.1); episode = Int(match.2); titleEnded = true; continue
            }
            if let value = Int(token), (1920...2100).contains(value), !titleTokens.isEmpty {
                year = value; titleEnded = true; continue
            }
            if lower.firstMatch(of: #/^(480|576|720|1080|2160)[pi]$/#) != nil || lower == "4k" {
                resolution = lower; titleEnded = true; continue
            }
            if release == nil, let tag = ParsedFilename.releaseTags.first(where: { lower.hasPrefix($0.0) })?.1 {
                release = tag; titleEnded = true; continue
            }
            if ["x264", "x265", "h264", "h265", "hevc", "aac", "ac3", "dts", "10bit", "hdr", "proper", "repack", "extended", "multi", "dual"].contains(lower) {
                titleEnded = true; continue
            }
            if !titleEnded { titleTokens.append(token) }
        }
        let title = titleTokens.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " -"))
        self.init(title: title.isEmpty ? base : title, year: year, season: season, episode: episode, release: release, resolution: resolution)
    }
}
