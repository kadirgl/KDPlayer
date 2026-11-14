#if DEBUG
import Foundation
import QuartzCore
import VLCKit

/// Teşhis: `KD_DEBUG_STATS=dosya` saniyede bir oynatma istatistiklerini yazar: çözülen/gösterilen/kaybolan
/// kare, bozuk veri, süreksizlik, kaybolan ses ve ana iş parçacığının o saniyedeki en uzun takılması.
@MainActor
final class PlaybackStats {
    static let shared = PlaybackStats()
    /// VLC'den gelen zaman olayı sayısı (saniyede kaç kez arayüz güncelleniyor).
    nonisolated(unsafe) static var timeEvents = 0
    private var timer: Timer?
    private var tick: Timer?
    private var lastTick = CACurrentMediaTime()
    private var worstStall: Double = 0
    private var previous: VLCMedia.Stats?
    private var start = Date.now

    func startIfRequested(player: PlayerController) {
        guard timer == nil, let path = ProcessInfo.processInfo.environment["KD_DEBUG_STATS"] else { return }
        try? "".write(toFile: path, atomically: true, encoding: .utf8)
        // 60 Hz'lik zamanlayıcı ana iş parçacığının takıldığı süreyi ölçer.
        tick = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = CACurrentMediaTime()
                self.worstStall = max(self.worstStall, now - self.lastTick - 1.0 / 60)
                self.lastTick = now
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample(player: player, path: path) }
        }
    }

    private func sample(player: PlayerController, path: String) {
        guard let media = player.mediaPlayer.media else { return }
        let stats = media.statistics
        let p = previous
        let line = String(format: "%5.1f t=%7.1f playing=%d decoded=%3d shown=%3d lost=%3d corrupt=%d discont=%d lostAudio=%d stall=%3.0fms timeEvents=%d\n",
                          Date.now.timeIntervalSince(start), player.time, player.isPlaying ? 1 : 0,
                          stats.decodedVideo - (p?.decodedVideo ?? 0),
                          stats.displayedPictures - (p?.displayedPictures ?? 0),
                          stats.lostPictures - (p?.lostPictures ?? 0),
                          stats.demuxCorrupted - (p?.demuxCorrupted ?? 0),
                          stats.demuxDiscontinuity - (p?.demuxDiscontinuity ?? 0),
                          stats.lostAudioBuffers - (p?.lostAudioBuffers ?? 0),
                          worstStall * 1000, Self.timeEvents)
        Self.timeEvents = 0
        previous = stats
        worstStall = 0
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        }
    }
}
#endif
