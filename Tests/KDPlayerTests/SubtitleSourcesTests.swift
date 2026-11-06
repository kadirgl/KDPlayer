import Foundation
import Testing
@testable import KDPlayer

@Suite("İkinci altyazı kaynakları")
struct SubtitleSourcesTests {
    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kd-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Klasörü `ditto` ile zip'ler (gerçek altyazı paketleri gibi).
    private func zip(_ folder: URL) throws -> Data {
        let out = folder.deletingLastPathComponent().appendingPathComponent("\(UUID().uuidString).zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", folder.path, out.path]
        try process.run()
        process.waitUntilExit()
        defer { try? FileManager.default.removeItem(at: out) }
        return try Data(contentsOf: out)
    }

    private let srt = "1\n00:00:01,000 --> 00:00:02,000\nMerhaba\n"

    @Test func extractsSubtitleFromZip() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pack = dir.appendingPathComponent("pack", isDirectory: true)
        try FileManager.default.createDirectory(at: pack, withIntermediateDirectories: true)
        try srt.write(to: pack.appendingPathComponent("Film.2003.tr.srt"), atomically: true, encoding: .utf8)
        try "okuma".write(to: pack.appendingPathComponent("okuyun.txt"), atomically: true, encoding: .utf8)
        let (data, name) = try SubtitleArchive.subtitleData(from: try zip(pack))
        #expect(name == "Film.2003.tr.srt")
        #expect(String(decoding: data, as: UTF8.self) == srt)
    }

    @Test func picksMatchingEpisodeFromSeasonPack() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pack = dir.appendingPathComponent("pack", isDirectory: true)
        try FileManager.default.createDirectory(at: pack, withIntermediateDirectories: true)
        for episode in 1...3 {
            try (srt + String(repeating: "x", count: episode * 10))
                .write(to: pack.appendingPathComponent("Dizi.S01E0\(episode).srt"), atomically: true, encoding: .utf8)
        }
        let (_, name) = try SubtitleArchive.subtitleData(from: try zip(pack), episode: "S01E02")
        #expect(name == "Dizi.S01E02.srt")
    }

    @Test func detectsRarAndPlainSubtitles() {
        #expect(SubtitleArchive.kind(of: Data("Rar!\u{1A}\u{07}".utf8)) == .rar)
        #expect(SubtitleArchive.kind(of: Data([0x50, 0x4B, 0x03, 0x04, 0x00])) == .zip)
        #expect(SubtitleArchive.kind(of: Data(srt.utf8)) == .subtitle)
        #expect(throws: SubtitleArchive.ArchiveError.self) { _ = try SubtitleArchive.subtitleData(from: Data("Rar!\u{1A}\u{07}".utf8)) }
    }

    @Test func savesNextToVideoWithoutOverwriting() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let video = dir.appendingPathComponent("Film.2003.mkv")
        let saved = try #require(SubtitleArchive.saveNextToVideo(text: srt, video: video, language: "tr", format: "srt"))
        #expect(saved.lastPathComponent == "Film.2003.tr.srt")
        // Aynı içerik: aynı dosya döner. Farklı içerik: kullanıcının dosyasına dokunulmaz.
        #expect(SubtitleArchive.saveNextToVideo(text: srt, video: video, language: "tr", format: "srt") == saved)
        #expect(SubtitleArchive.saveNextToVideo(text: "başka", video: video, language: "tr", format: "srt") == nil)
        #expect(try String(contentsOf: saved, encoding: .utf8) == srt)
    }

    @Test func parsesSubdlResponse() throws {
        let json = """
        {"status":true,"results":[{"name":"Dizi","type":"tv","year":2020}],
         "subtitles":[
          {"release_name":"Dizi.S01E02.1080p.WEB-DL","name":"a.zip","lang":"turkish","language":"TR","url":"/subtitle/1-2.zip","season":1,"episode":2,"fps":"23.976","hi":false,"full_season":false},
          {"release_name":"Dizi.S01E03.1080p.WEB-DL","name":"b.zip","language":"TR","url":"/subtitle/1-3.zip","season":1,"episode":3,"hi":false,"full_season":false},
          {"release_name":"Dizi.S01.Pack","name":"c.zip","language":"TR","url":"/subtitle/1-9.zip?api_key=gizli","season":1,"episode":0,"hi":true,"full_season":true},
          {"release_name":"Dizi.S01E02.rar","name":"d.rar","language":"TR","url":"/subtitle/1-7.rar?api_key=gizli","season":1,"episode":2,"hi":false,"full_season":false}
         ]}
        """
        let results = try SubdlClient.parse(Data(json.utf8), season: 1, episode: 2)
        #expect(results.map(\.path) == ["/subtitle/1-2.zip", "/subtitle/1-9.zip"])
        #expect(results[0].language == "tr")
        #expect(results[0].fps == 23.976)
        #expect(results[1].fullSeason && results[1].hearingImpaired)
    }

    @Test func subdlNotFoundIsEmptyNotError() throws {
        let json = #"{"status":false,"error":"can't find movie or tv"}"#
        #expect(try SubdlClient.parse(Data(json.utf8), season: nil, episode: nil).isEmpty)
        let bad = #"{"status":false,"error":"invalid api key"}"#
        #expect(throws: SubdlClient.ClientError.self) { _ = try SubdlClient.parse(Data(bad.utf8), season: nil, episode: nil) }
    }

    @Test func buildsTurkceAltyaziSearchURL() {
        let url = PlayerSession.turkceAltyaziSearchURL(for: "Memories Of Murder 2003")
        #expect(url.absoluteString == "https://turkcealtyazi.org/find.php?cat=sub&find=Memories+Of+Murder+2003")
    }

    @Test func downloadsScanIgnoresPartialAndOldFiles() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let start = Date.now
        try srt.write(to: dir.appendingPathComponent("yeni.zip"), atomically: true, encoding: .utf8)
        try srt.write(to: dir.appendingPathComponent("yarim.zip.crdownload"), atomically: true, encoding: .utf8)
        try srt.write(to: dir.appendingPathComponent("film.mkv"), atomically: true, encoding: .utf8)
        let old = dir.appendingPathComponent("eski.srt")
        try srt.write(to: old, atomically: true, encoding: .utf8)
        let past = Date.now.addingTimeInterval(-3600)
        try FileManager.default.setAttributes([.creationDate: past, .modificationDate: past], ofItemAtPath: old.path)
        let names = DownloadsWatcher.candidates(in: dir, since: start).map { $0.0.lastPathComponent }
        #expect(names == ["yeni.zip"])
    }
}
