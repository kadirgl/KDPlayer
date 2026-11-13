import Foundation
import Testing
@testable import KDPlayer

@Suite("Video bilgisi")
struct VideoInfoTests {
    private func video(_ width: Int, _ height: Int) -> MediaTrack {
        var track = MediaTrack(id: -1, kind: .video, vlcName: "", info: nil)
        track.width = width
        track.height = height
        return track
    }

    @Test func fpsKeepsFraction() {
        // 23,976 ile 24 altyazı uyumu için farklıdır; yuvarlanmamalı.
        #expect(Format.fps(24000.0 / 1001.0) == "23,976 fps")
        #expect(Format.fps(25) == "25 fps")
        #expect(Format.fps(30000.0 / 1001.0) == "29,97 fps")
    }

    @Test func resolutionLabelMatchesReleaseNames() {
        #expect(video(3840, 2160).resolutionLabel == "2160p")
        #expect(video(3840, 2076).resolutionLabel == "2160p") // sinemaskop 4K
        #expect(video(1920, 800).resolutionLabel == "1080p")
        #expect(video(1280, 536).resolutionLabel == "720p")
        #expect(video(720, 576).resolutionLabel == "576p")
        #expect(video(1080, 1920).resolutionLabel == "1920p") // dikey video olduğu gibi
    }
}

@Suite("Geçmişteki dosyayı bulma")
struct RecordLocatorTests {
    @Test func findsMovedFileByBookmarkAndReportsDeleted() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kd-loc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = dir.appendingPathComponent("Film.2020.mkv")
        try Data("video".utf8).write(to: original)
        let bookmark = try original.bookmarkData()
        #expect(RecordLocator.locate(path: original.path, bookmark: bookmark) == .available)

        // Taşındı / yeniden adlandırıldı: yer imi yeni yeri bulur.
        let sub = dir.appendingPathComponent("Filmler", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let moved = sub.appendingPathComponent("Film (2020).mkv")
        try FileManager.default.moveItem(at: original, to: moved)
        let state = RecordLocator.locate(path: original.path, bookmark: bookmark)
        guard case .moved(let newPath) = state else {
            Issue.record("taşınan dosya bulunamadı: \(state)")
            return
        }
        // /var ↔ /private/var farkı olabilir: aynı dosya mı?
        #expect(URL(fileURLWithPath: newPath).lastPathComponent == "Film (2020).mkv")
        #expect(FileManager.default.contentsEqual(atPath: newPath, andPath: moved.path))

        // Silindi: bulunamaz.
        try FileManager.default.removeItem(at: moved)
        #expect(RecordLocator.locate(path: original.path, bookmark: bookmark) == .missing)
        #expect(RecordLocator.locate(path: original.path, bookmark: nil) == .missing)
    }
}
