import Foundation
import Testing
import VLCKit
@testable import KDPlayer

@Suite("Gömülü VLCKit çözücüleri")
struct CodecSupportTests {
    /// scripts/build-vlckit.sh ile derlenen pakette Vendor/VLCKit.source "… truehd" yazar.
    private var builtWithTrueHD: Bool {
        let marker = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Vendor/VLCKit.source")
        return (try? String(contentsOf: marker, encoding: .utf8))?.contains("truehd") ?? false
    }

    private func audioTrack(fourCC: String) -> MediaTrack {
        let value = fourCC.utf8.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
        return MediaTrack(id: 1, kind: .audio, vlcName: "English", info: [
            VLCMediaTracksInformationCodec: NSNumber(value: value),
            VLCMediaTracksInformationAudioChannelsNumber: NSNumber(value: 8),
        ])
    }

    @Test func detectsLinkedDecoders() {
        #expect(CodecSupport.hasDecoder("ac3"))
        #expect(CodecSupport.hasDecoder("eac3"))
        #expect(!CodecSupport.hasDecoder("kd_yok"))
    }

    @Test func trueHDMatchesBuild() {
        #expect(CodecSupport.trueHD == builtWithTrueHD)
        let trueHD = audioTrack(fourCC: "trhd")
        #expect(trueHD.codec == "TrueHD")
        #expect(trueHD.isUnsupported == !builtWithTrueHD)
        #expect(!audioTrack(fourCC: "a52 ").isUnsupported)
    }
}
