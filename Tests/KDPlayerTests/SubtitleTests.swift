import Foundation
import Testing
@testable import KDPlayer

@Suite("Altyazı ayrıştırma")
struct SubtitleParserTests {
    @Test func parsesSRT() throws {
        let srt = """
        1
        00:00:01,000 --> 00:00:02,500
        <i>Merhaba</i> dünya

        2
        00:01:04,120 --> 00:01:06,000
        Bu şehirde kimse geç kalmaz,
        sadece biraz erken gider.
        """
        let document = try SubtitleParser.parse(srt)
        #expect(document.format == .srt)
        #expect(document.cues.count == 2)
        #expect(document.cues[0].text == "Merhaba dünya")
        #expect(document.cues[1].start == 64.12)
        #expect(document.cues[1].text.contains("\n"))
    }

    @Test func parsesASSWithCommasAndTags() throws {
        let ass = """
        [Script Info]
        Title: test

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:05.00,0:00:07.50,Default,,0,0,0,,{\\an8}Üstte, virgüllü\\Nikinci satır
        Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,İlk
        """
        let document = try SubtitleParser.parse(ass)
        #expect(document.format == .ass)
        #expect(document.cues.first?.text == "İlk")
        #expect(document.cues[1].text == "Üstte, virgüllü\nikinci satır")
        #expect(document.cues[1].top)
    }

    @Test func lookupAppliesTiming() throws {
        let document = try SubtitleParser.parse("1\n00:00:10,000 --> 00:00:12,000\nA\n\n2\n00:00:20,000 --> 00:00:22,000\nB\n")
        #expect(document.cues(at: 11, timing: .identity).map(\.text) == ["A"])
        #expect(document.cues(at: 15, timing: .identity).isEmpty)
        // +300 ms gecikme: satır 10,3'te başlar.
        let delayed = SubtitleTiming(scale: 1, offset: 0.3)
        #expect(document.cues(at: 10.1, timing: delayed).isEmpty)
        #expect(document.cues(at: 10.4, timing: delayed).map(\.text) == ["A"])
    }

    @Test func rangeLookupMatchesLinearScan() throws {
        var srt = ""
        for i in 0..<300 { srt += "\(i + 1)\n\(SubtitleTests.ts(Double(i) * 3)) --> \(SubtitleTests.ts(Double(i) * 3 + 2))\nSatır \(i)\n\n" }
        let document = try SubtitleParser.parse(srt)
        let timing = SubtitleTiming(scale: 1.04, offset: 0.7)
        for start in stride(from: -10.0, through: 950, by: 37) {
            let range = start...(start + 30)
            let expected = document.cues.filter {
                timing.displayTime(for: $0.end) > range.lowerBound && timing.displayTime(for: $0.start) <= range.upperBound
            }
            #expect(document.cues(in: range, timing: timing).map(\.id) == expected.map(\.id))
        }
    }
}

@Suite("Karakter kodlaması")
struct DecoderTests {
    let turkish = "Şişli'de ığdır çğüöş İĞÜŞÇÖ"

    @Test func decodesWindows1254() throws {
        let data = try #require(turkish.data(using: SubtitleTextDecoder.windows1254))
        let result = try #require(SubtitleTextDecoder.decode(data))
        #expect(result.text == turkish)
        #expect(result.encodingName == "Windows-1254")
        #expect(result.repairNote == "Windows-1254 → UTF-8")
    }

    @Test func keepsUTF8() throws {
        let result = try #require(SubtitleTextDecoder.decode(Data(turkish.utf8)))
        #expect(result.text == turkish)
        #expect(result.repairNote == nil)
    }

    @Test func repairsMojibake() throws {
        // UTF-8 baytları cp1252 sanılıp yeniden UTF-8 kaydedilmiş metin.
        let broken = try #require(String(data: Data("Gülüşmeler çok güzel".utf8), encoding: .windowsCP1252))
        #expect(SubtitleTextDecoder.looksBroken(broken))
        let result = try #require(SubtitleTextDecoder.decode(Data(broken.utf8)))
        #expect(result.text == "Gülüşmeler çok güzel")
    }
}

@Suite("Senkron")
struct TimingTests {
    @Test func twoPointSyncComputesScale() throws {
        // Kaynak 25 fps, görüntü 23,976: görüntü = 1,0427 × kaynak.
        var srt = ""
        for i in 0..<200 { srt += "\(i + 1)\n\(SubtitleTests.ts(Double(i) * 10)) --> \(SubtitleTests.ts(Double(i) * 10 + 2))\nSatır \(i)\n\n" }
        let service = SubtitleService()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("kd-sync-test.srt")
        try srt.write(to: file, atomically: true, encoding: .utf8)
        #expect(service.loadUserFile(file))
        let scale = 25.0 / 23.976
        #expect(service.markSpeech(at: 100 * scale))
        #expect(service.markSpeech(at: 1500 * scale))
        #expect(abs(service.timing.scale - scale) < 0.001)
        #expect(abs(service.timing.offset) < 0.05)
    }
}

enum SubtitleTests {
    static func ts(_ t: Double) -> String {
        let h = Int(t) / 3600, m = Int(t) % 3600 / 60, s = Int(t) % 60, ms = Int((t - Double(Int(t))) * 1000)
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }
}

@Suite("Dosya kimliği")
struct IdentityTests {
    @Test func parsesMovieFilename() {
        let parsed = ParsedFilename(filename: "Son.Vapur.2025.1080p.WEB-DL.x265-GRP.mkv")
        #expect(parsed.title == "Son Vapur")
        #expect(parsed.year == 2025)
        #expect(parsed.release == "WEB-DL")
        #expect(parsed.resolution == "1080p")
    }

    @Test func parsesEpisodeFilename() {
        let parsed = ParsedFilename(filename: "Fener.S02E06.HDTV.mkv")
        #expect(parsed.title == "Fener")
        #expect(parsed.episodeCode == "S02E06")
        #expect(parsed.release == "HDTV")
    }

    @Test func movieHashMatchesReference() throws {
        // OpenSubtitles referansı: 128 KB sıfır + boyut → boyutun hex'i.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("kd-hash-test.bin")
        try Data(count: 200_000).write(to: file)
        #expect(try MovieHash.compute(for: file) == String(format: "%016llx", UInt64(200_000)))
    }
}
