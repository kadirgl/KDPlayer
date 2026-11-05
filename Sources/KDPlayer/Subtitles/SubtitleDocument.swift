import Foundation

/// Tek altyazı satırı (blok). Zamanlar saniye cinsinden, kaynaktaki haliyle.
struct SubtitleCue: Identifiable, Equatable, Sendable {
    let id: Int
    var start: Double
    var end: Double
    var text: String
    /// ASS'de üstte konumlanmış ({\an8}) satırlar.
    var top = false
}

/// Ayrıştırılmış altyazı dosyası. Senkron `t' = a·t + b` dönüşümüyle uygulanır.
struct SubtitleDocument: Equatable, Sendable {
    var cues: [SubtitleCue]
    var format: Format

    enum Format: String, Sendable { case srt, ass, vtt }

    var isEmpty: Bool { cues.isEmpty }

    /// Filmin `time` anında görünen satırlar (offset ve ölçek uygulanmış).
    func cues(at time: Double, timing: SubtitleTiming) -> [SubtitleCue] {
        // Ters dönüşüm: kaynak zamanı = (t - b) / a
        let source = timing.sourceTime(for: time)
        guard let index = firstIndex(endingAfter: source) else { return [] }
        var result: [SubtitleCue] = []
        var i = index
        // Çakışan satırlar için ileri bak (genelde 1–2).
        while i < cues.count, cues[i].start <= source {
            if cues[i].end > source { result.append(cues[i]) }
            i += 1
        }
        return result
    }

    /// Belirli bir anda ya da hemen sonra gelen satır ("Bu sahnede" önizlemesi, Duy ve bas).
    func cue(nearest time: Double, timing: SubtitleTiming = .identity) -> SubtitleCue? {
        let source = timing.sourceTime(for: time)
        guard let index = firstIndex(endingAfter: source) else { return cues.last }
        return cues[index]
    }

    /// Kaynak zamanından sonra başlayan ilk satır.
    func nextCue(after time: Double, timing: SubtitleTiming) -> SubtitleCue? {
        let source = timing.sourceTime(for: time)
        return cues.first { $0.start >= source }
    }

    /// `end > time` olan ilk satır (ikili arama).
    private func firstIndex(endingAfter time: Double) -> Int? {
        var low = 0, high = cues.count
        while low < high {
            let mid = (low + high) / 2
            if cues[mid].end <= time { low = mid + 1 } else { high = mid }
        }
        return low < cues.count ? low : nil
    }

    /// Görüntü zamanı aralığındaki satırlar (ikili arama; senkron şeridi saniyede birkaç kez çağırır).
    func cues(in range: ClosedRange<Double>, timing: SubtitleTiming) -> [SubtitleCue] {
        let lower = timing.sourceTime(for: range.lowerBound), upper = timing.sourceTime(for: range.upperBound)
        guard var index = firstIndex(endingAfter: min(lower, upper)) else { return [] }
        var result: [SubtitleCue] = []
        while index < cues.count, cues[index].start <= max(lower, upper) {
            result.append(cues[index])
            index += 1
        }
        return result
    }
}

/// Senkron: görüntü zamanı = a · kaynak + b. a = ölçek (FPS farkı), b = offset (sn).
struct SubtitleTiming: Equatable, Codable, Sendable {
    var scale: Double = 1
    var offset: Double = 0

    static let identity = SubtitleTiming()

    var offsetMilliseconds: Int { Int((offset * 1000).rounded()) }

    func displayTime(for source: Double) -> Double { scale * source + offset }
    func sourceTime(for display: Double) -> Double { (display - offset) / scale }

    /// FPS farkını düzeltir (ör. 25 → 23,976).
    static func fps(from source: Double, to target: Double) -> Double { source / target }
}
