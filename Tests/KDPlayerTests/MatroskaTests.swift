import Foundation
import Testing
@testable import KDPlayer

@Suite("Gömülü altyazı (MKV)")
struct MatroskaSubtitleTests {
    private var fixture: URL {
        Bundle.module.url(forResource: "subtitles", withExtension: "mkv", subdirectory: "Fixtures")!
    }

    @Test func readsTracks() throws {
        let reader = try MatroskaSubtitleReader(url: fixture)
        #expect(reader.tracks.count == 2)
        #expect(reader.tracks[0].codecID == "S_TEXT/UTF8")
        #expect(reader.tracks[0].language == "tur")
        #expect(reader.tracks[1].codecID == "S_TEXT/ASS")
        #expect(reader.tracks.allSatisfy { $0.isText })
    }

    @Test func extractsSRTCues() throws {
        let reader = try MatroskaSubtitleReader(url: fixture)
        let cues = try reader.cues(for: reader.tracks[0].number)
        #expect(cues.count == 2)
        #expect(abs(cues[0].start - 0.2) < 0.01)
        #expect(abs(cues[0].end - 0.9) < 0.01)
        #expect(cues[0].text == "Merhaba dünya\nİkinci satır")
        #expect(cues[1].text == "Üstte")
        #expect(cues[1].top)
    }

    @Test func extractsASSCues() throws {
        let reader = try MatroskaSubtitleReader(url: fixture)
        let cues = try reader.cues(for: reader.tracks[1].number)
        #expect(cues.count == 1)
        #expect(cues[0].text == "Hello, world\nline two")
        #expect(abs(cues[0].start - 0.5) < 0.01)
        #expect(abs(cues[0].end - 1.5) < 0.01)
    }

    @Test func rejectsNonMatroska() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("not-mkv-\(UUID().uuidString).mkv")
        try? Data("hello".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: (any Error).self) { _ = try MatroskaSubtitleReader(url: url) }
    }

    @Test func mapsVLCTracksByOrder() async {
        let extractor = EmbeddedSubtitleExtractor(url: fixture)
        let english = await extractor.document(forVLCTrack: 2, order: [(id: 1, language: "tr"), (id: 2, language: "en")])
        #expect(english?.cues.first?.text == "Hello, world\nline two")
        // Dil tutmuyorsa yanlış altyazı çizmektense VLC'ye bırakılır.
        let mismatch = await extractor.document(forVLCTrack: 1, order: [(id: 1, language: "de"), (id: 2, language: "en")])
        #expect(mismatch == nil)
    }

    @Test func inflatesZlib() throws {
        // "Merhaba" zlib ile sıkıştırılmış (Python zlib.compress).
        let bytes: [UInt8] = [0x78, 0x9C, 0xF3, 0x4D, 0x2D, 0xCA, 0x48, 0x4C, 0x4A, 0x04, 0x00, 0x0A, 0xA2, 0x02, 0xB1]
        let output = try #require(MatroskaSubtitleReader.inflateZlib(Data(bytes)))
        #expect(String(decoding: output, as: UTF8.self) == "Merhaba")
    }

    @Test func normalizesLanguageNames() {
        #expect(Language.code(for: "English") == "en")
        #expect(Language.code(for: "spa") == "spa")
        #expect(Language.code(for: "Finnish") == "fi")
    }
}
