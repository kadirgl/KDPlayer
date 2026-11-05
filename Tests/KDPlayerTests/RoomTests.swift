import Foundation
import Testing
@testable import KDPlayer

@Suite("Oda")
struct RoomTests {
    @Test func subtitleRoundTrip() throws {
        let text = String(repeating: "1\n00:00:01,000 --> 00:00:02,000\nŞişli'de ığdır çğüöş\n\n", count: 500)
        let packed = try #require(RoomSubtitle.pack(text))
        #expect(packed.count < text.utf8.count / 5)
        let shared = RoomSubtitle(lang: "tr", source: "file", name: "a.srt", contentGz: packed, offsetMs: 300, scale: 1, by: "u", version: 1)
        #expect(shared.unpackedText() == text)
        #expect(shared.timing.offsetMilliseconds == 300)
    }

    @Test func jsonTreeAppliesPutAndPatch() {
        var tree = JSONTree()
        tree.apply(RoomStreamEvent(kind: .put, path: "/", data: ["meta": ["name": "Oda"], "members": ["a": ["name": "A"]]]))
        tree.apply(RoomStreamEvent(kind: .put, path: "/members/b", data: ["name": "B"]))
        tree.apply(RoomStreamEvent(kind: .patch, path: "/members/a", data: ["status": "ready", "driftMs": 12]))
        tree.apply(RoomStreamEvent(kind: .put, path: "/meta/name", data: "Yeni"))
        let members = tree.root["members"] as? [String: Any]
        #expect(members?.count == 2)
        #expect((members?["a"] as? [String: Any])?["status"] as? String == "ready")
        #expect((tree.root["meta"] as? [String: Any])?["name"] as? String == "Yeni")
        tree.apply(RoomStreamEvent(kind: .put, path: "/members/b", data: nil))
        #expect((tree.root["members"] as? [String: Any])?.count == 1)
    }

    @Test func expectedPositionAdvancesOnlyWhenPlaying() {
        let playing = RoomPlayback(playing: true, positionMs: 60_000, rate: 1.25, updatedAt: 1_000, by: "a", seq: 1, action: "play")
        #expect(playing.expectedPosition(serverNow: 3_000) == 62.5)
        let paused = RoomPlayback(playing: false, positionMs: 60_000, rate: 1, updatedAt: 1_000, by: "a", seq: 1, action: "pause")
        #expect(paused.expectedPosition(serverNow: 9_000) == 60)
    }

    @Test func parsesCodesAndTimestamps() {
        #expect(RoomService.normalize("kdplayer://join/k7x2qm") == "K7X2QM")
        #expect(RoomService.normalize("https://kdplayer.app/j/K7X2QM ") == "K7X2QM")
        #expect(RoomMessage.timestamp(in: "Şu sahneyi bir daha izleyelim 41:52") == 2_512_000)
        #expect(RoomMessage.timestamp(in: "1:02:03'te") == 3_723_000)
        #expect(RoomMessage.timestamp(in: "selam") == nil)
        let code = RoomService.generateCode()
        #expect(code.count == 6)
        #expect(!code.contains { "01OI".contains($0) })
    }
}

@Suite("Güncelleme")
struct UpdateTests {
    @Test func comparesVersions() {
        #expect(AppUpdater.isNewer("0.1.10", than: "0.1.9"))
        #expect(AppUpdater.isNewer("1.0", than: "0.9.9"))
        #expect(!AppUpdater.isNewer("0.1.0", than: "0.1.0"))
        #expect(!AppUpdater.isNewer("0.1", than: "0.1.0"))
        #expect(!AppUpdater.isNewer("0.0.9", than: "0.1.0"))
    }

    @Test func notesSummaryDropsInstallSection() {
        let notes = "## Değişiklikler\n\n- Hızlı açılış\n\n---\n**Kurulum:** …"
        #expect(UpdateSettingsSection.summary(of: notes) == "- Hızlı açılış")
    }
}
