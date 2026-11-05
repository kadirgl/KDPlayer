import Foundation
import Compression

/// MKV/WebM içindeki metin altyazılarını (SRT, ASS/SSA, WebVTT) okur; böylece gömülü altyazı da
/// VLC yerine bizim katmanımızda, kullanıcının boyut/renk/yazı tipi ayarlarıyla çizilir.
///
/// Dosyanın tamamını okumaz: önce dizindeki (Cues) altyazı girdilerinden doğrudan bloklara atlar;
/// dizin altyazıları kapsamıyorsa kümeleri yalnızca başlıklarını okuyarak tarar.
final class MatroskaSubtitleReader {
    struct Track: Equatable, Sendable {
        let number: UInt64
        let codecID: String
        let language: String?
        let name: String?
        let forced: Bool
        /// ASS/SSA başlığı ([Script Info], [V4+ Styles]).
        let codecPrivate: Data?
        let compression: Compression?

        enum Compression: Equatable, Sendable {
            case zlib
            case headerStripping(Data)
        }

        var isText: Bool { MatroskaSubtitleReader.textCodecs.contains(codecID) }
    }

    enum ReadError: Error { case notMatroska, noSegment, unsupported }

    static let textCodecs: Set<String> = ["S_TEXT/UTF8", "S_TEXT/ASCII", "S_TEXT/ASS", "S_TEXT/SSA", "S_TEXT/WEBVTT", "S_ASS", "S_SSA"]

    let url: URL
    private(set) var tracks: [Track] = []
    /// Tüm parçalar (ses/görüntü dahil) dosyadaki sırasıyla; VLC parça kimlikleriyle eşleştirmek için.
    private(set) var allTrackTypes: [(number: UInt64, type: UInt64)] = []

    private let handle: FileHandle
    private let fileSize: UInt64
    private var segmentStart: UInt64 = 0
    private var segmentEnd: UInt64 = 0
    private var timestampScale: UInt64 = 1_000_000
    private var cuesPosition: UInt64?
    private var clustersStart: UInt64?
    /// Parça numarası → dizindeki (küme konumu, küme içi göreli konum) girdileri.
    private var cueEntries: [UInt64: [(cluster: UInt64, relative: UInt64?)]]?
    private var clusterTimestamps: [UInt64: UInt64] = [:]

    init(url: URL) throws {
        self.url = url
        handle = try FileHandle(forReadingFrom: url)
        fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
        try parseHeader()
    }

    deinit { try? handle.close() }

    static func canRead(_ url: URL) -> Bool {
        ["mkv", "mka", "mks", "webm"].contains(url.pathExtension.lowercased())
    }

    // MARK: Okuma

    /// Parçanın tüm satırları (başlangıca göre sıralı).
    func cues(for trackNumber: UInt64) throws -> [SubtitleCue] {
        guard let track = tracks.first(where: { $0.number == trackNumber }), track.isText else { throw ReadError.unsupported }
        var blocks: [Block] = []
        if let entries = try indexedEntries()[trackNumber], !entries.isEmpty {
            blocks = try readIndexed(entries, track: trackNumber)
        } else {
            blocks = try scanClusters(tracks: [trackNumber])[trackNumber] ?? []
        }
        return makeCues(blocks, track: track)
    }

    // MARK: Başlık

    private func parseHeader() throws {
        var offset: UInt64 = 0
        guard let ebml = try header(at: &offset), ebml.id == 0x1A45DFA3 else { throw ReadError.notMatroska }
        offset = ebml.dataStart + ebml.size
        var segment: Element?
        while offset < fileSize, let next = try header(at: &offset) {
            if next.id == 0x18538067 { segment = next; break }
            offset = next.dataStart + next.size
        }
        guard let segment else { throw ReadError.noSegment }
        segmentStart = segment.dataStart
        segmentEnd = segment.unknownSize ? fileSize : min(fileSize, segment.dataStart + segment.size)

        // Üst düzey öğeler: SeekHead, Info, Tracks; ilk kümeye gelince dur (dizin başka yerdeyse SeekHead söyler).
        var position = segmentStart
        var seekTargets: [UInt32: UInt64] = [:]
        var tracksParsed = false, infoParsed = false
        while position < segmentEnd, let child = try header(at: &position) {
            switch child.id {
            case 0x114D9B74: // SeekHead
                for seek in try children(of: child) where seek.id == 0x4DBB {
                    var id: UInt32?, pos: UInt64?
                    for item in try children(of: seek) {
                        if item.id == 0x53AB { id = UInt32(truncatingIfNeeded: try readUInt(item)) }
                        if item.id == 0x53AC { pos = try readUInt(item) }
                    }
                    if let id, let pos { seekTargets[id] = segmentStart + pos }
                }
            case 0x1549A966: // Info
                try parseInfo(child); infoParsed = true
            case 0x1654AE6B: // Tracks
                try parseTracks(child); tracksParsed = true
            case 0x1C53BB6B: // Cues
                cuesPosition = child.offset
            case 0x1F43B675: // Cluster
                clustersStart = clustersStart ?? child.offset
            default: break
            }
            if child.id == 0x1F43B675 || child.unknownSize { break }
            position = child.dataStart + child.size
        }
        if !infoParsed, let pos = seekTargets[0x1549A966] {
            var offset = pos
            if let info = try header(at: &offset), info.id == 0x1549A966 { try parseInfo(info) }
        }
        if !tracksParsed, let pos = seekTargets[0x1654AE6B] {
            var offset = pos
            if let element = try header(at: &offset), element.id == 0x1654AE6B { try parseTracks(element) }
        }
        if cuesPosition == nil, let pos = seekTargets[0x1C53BB6B] { cuesPosition = pos }
        if clustersStart == nil, let pos = seekTargets[0x1F43B675] { clustersStart = pos }
    }

    private func parseInfo(_ info: Element) throws {
        for item in try children(of: info) where item.id == 0x2AD7B1 {
            let scale = try readUInt(item)
            if scale > 0 { timestampScale = scale }
        }
    }

    private func parseTracks(_ element: Element) throws {
        var result: [Track] = []
        var types: [(UInt64, UInt64)] = []
        for entry in try children(of: element) where entry.id == 0xAE {
            var number: UInt64 = 0, type: UInt64 = 0, codec = ""
            var language: String? = "eng", name: String?
            var forced = false
            var codecPrivate: Data?
            var compression: Track.Compression?
            for item in try children(of: entry) {
                switch item.id {
                case 0xD7: number = try readUInt(item)
                case 0x83: type = try readUInt(item)
                case 0x86: codec = try readString(item)
                case 0x22B59C: language = try readString(item)
                case 0x536E: name = try readString(item)
                case 0x55AA: forced = try readUInt(item) == 1
                case 0x63A2: codecPrivate = try read(item)
                case 0x6D80: compression = try parseEncodings(item)
                default: break
                }
            }
            types.append((number, type))
            if type == 0x11 {
                // VLC de eski Language öğesini okur; parça eşleştirmesi için aynısı kullanılır.
                result.append(Track(number: number, codecID: codec, language: language == "und" ? nil : language, name: name,
                                    forced: forced, codecPrivate: codecPrivate, compression: compression))
            }
        }
        tracks = result
        allTrackTypes = types
    }

    private func parseEncodings(_ element: Element) throws -> Track.Compression? {
        for encoding in try children(of: element) where encoding.id == 0x6240 {
            var type: UInt64 = 0
            var compression: Element?
            for item in try children(of: encoding) {
                if item.id == 0x5033 { type = try readUInt(item) }
                if item.id == 0x5034 { compression = item }
            }
            guard type == 0, let compression else { continue }
            var algorithm: UInt64 = 0
            var settings = Data()
            for item in try children(of: compression) {
                if item.id == 0x4254 { algorithm = try readUInt(item) }
                if item.id == 0x4255 { settings = try read(item) }
            }
            switch algorithm {
            case 0: return .zlib
            case 3: return .headerStripping(settings)
            default: return nil
            }
        }
        return nil
    }

    // MARK: Dizin (Cues)

    private func indexedEntries() throws -> [UInt64: [(cluster: UInt64, relative: UInt64?)]] {
        if let cueEntries { return cueEntries }
        var result: [UInt64: [(cluster: UInt64, relative: UInt64?)]] = [:]
        let subtitleNumbers = Set(tracks.map(\.number))
        if let position = cuesPosition {
            var offset = position
            if let cues = try header(at: &offset), cues.id == 0x1C53BB6B, cues.size < 256 << 20 {
                // Dizini tek seferde oku (altyazılı büyük dosyalarda birkaç MB).
                let data = try read(cues)
                var reader = BufferReader(data: data)
                while let point = reader.nextElement() {
                    guard point.id == 0xBB else { reader.skip(point); continue }
                    var inner = reader.sub(point)
                    reader.skip(point)
                    while let item = inner.nextElement() {
                        guard item.id == 0xB7 else { inner.skip(item); continue }
                        var positions = inner.sub(item)
                        inner.skip(item)
                        var track: UInt64 = 0, cluster: UInt64?, relative: UInt64?
                        while let field = positions.nextElement() {
                            switch field.id {
                            case 0xF7: track = positions.uint(field)
                            case 0xF1: cluster = positions.uint(field)
                            case 0xF0: relative = positions.uint(field)
                            default: break
                            }
                            positions.skip(field)
                        }
                        if subtitleNumbers.contains(track), let cluster {
                            result[track, default: []].append((segmentStart + cluster, relative))
                        }
                    }
                }
            }
        }
        cueEntries = result
        return result
    }

    private struct Block {
        var timestamp: Int64   // ölçeklenmemiş (TimestampScale birimi)
        var duration: UInt64?
        var payload: Data
    }

    /// Dizin girdilerinden bloklara doğrudan atlar.
    private func readIndexed(_ entries: [(cluster: UInt64, relative: UInt64?)], track: UInt64) throws -> [Block] {
        var blocks: [Block] = []
        var seen = Set<UInt64>()
        // Göreli konumu olmayan girdiler için kümeyi baştan tara.
        var clustersToScan = Set<UInt64>()
        for entry in entries {
            guard let relative = entry.relative else { clustersToScan.insert(entry.cluster); continue }
            guard let clusterTime = try clusterTimestamp(at: entry.cluster) else { continue }
            var dataStart = entry.cluster
            guard let cluster = try header(at: &dataStart), cluster.id == 0x1F43B675 else { continue }
            let position = cluster.dataStart + relative
            guard seen.insert(position).inserted else { continue }
            var offset = position
            guard let element = try header(at: &offset) else { continue }
            if let block = try readBlock(element, track: track, clusterTime: clusterTime) { blocks.append(block) }
        }
        for cluster in clustersToScan {
            blocks += try scanCluster(at: cluster, tracks: [track])[track] ?? []
        }
        return blocks
    }

    private func clusterTimestamp(at position: UInt64) throws -> UInt64? {
        if let cached = clusterTimestamps[position] { return cached }
        var offset = position
        guard let cluster = try header(at: &offset), cluster.id == 0x1F43B675 else { return nil }
        var child = cluster.dataStart
        // Timestamp genelde ilk çocuktur; birkaç öğe içinde aranır.
        for _ in 0..<8 {
            guard let item = try header(at: &child) else { break }
            if item.id == 0xE7 {
                let value = try readUInt(item)
                clusterTimestamps[position] = value
                return value
            }
            if item.id == 0xA3 || item.id == 0xA0 { break }
            child = item.dataStart + item.size
        }
        return nil
    }

    /// SimpleBlock ya da BlockGroup → istenen parçanın bloğu.
    private func readBlock(_ element: Element, track: UInt64, clusterTime: UInt64) throws -> Block? {
        switch element.id {
        case 0xA3:
            return parseBlockData(try read(element), track: track, clusterTime: clusterTime, duration: nil)
        case 0xA0:
            var blockData: Data?, duration: UInt64?
            for item in try children(of: element) {
                if item.id == 0xA1 { blockData = try read(item) }
                if item.id == 0x9B { duration = try readUInt(item) }
            }
            guard let blockData else { return nil }
            return parseBlockData(blockData, track: track, clusterTime: clusterTime, duration: duration)
        default:
            return nil
        }
    }

    private func parseBlockData(_ data: Data, track: UInt64, clusterTime: UInt64, duration: UInt64?) -> Block? {
        var reader = BufferReader(data: data)
        guard let number = reader.vint(), number == track, reader.remaining >= 3 else { return nil }
        let relative = Int16(bitPattern: UInt16(reader.byte()) << 8 | UInt16(reader.byte()))
        let flags = reader.byte()
        guard flags & 0x06 == 0 else { return nil } // altyazıda lacing beklenmez
        return Block(timestamp: Int64(clusterTime) + Int64(relative), duration: duration, payload: reader.rest())
    }

    // MARK: Tarama (dizin yoksa)

    private func scanClusters(tracks wanted: Set<UInt64>) throws -> [UInt64: [Block]] {
        var result: [UInt64: [Block]] = [:]
        var position = clustersStart ?? segmentStart
        while position < segmentEnd, let element = try header(at: &position) {
            if element.id == 0x1F43B675 {
                for (track, blocks) in try scanCluster(element, tracks: wanted) { result[track, default: []] += blocks }
            }
            if element.unknownSize { break }
            position = element.dataStart + element.size
        }
        return result
    }

    private func scanCluster(at position: UInt64, tracks wanted: Set<UInt64>) throws -> [UInt64: [Block]] {
        var offset = position
        guard let cluster = try header(at: &offset), cluster.id == 0x1F43B675 else { return [:] }
        return try scanCluster(cluster, tracks: wanted)
    }

    private func scanCluster(_ cluster: Element, tracks wanted: Set<UInt64>) throws -> [UInt64: [Block]] {
        var result: [UInt64: [Block]] = [:]
        var clusterTime: UInt64 = 0
        var position = cluster.dataStart
        let end = cluster.unknownSize ? segmentEnd : cluster.dataStart + cluster.size
        while position < end, let item = try header(at: &position) {
            switch item.id {
            case 0xE7: clusterTime = try readUInt(item)
            case 0xA3, 0xA0:
                // Parça numarasını okumak için yalnızca ilk birkaç bayt.
                if let number = try peekTrackNumber(item), wanted.contains(number),
                   let block = try readBlock(item, track: number, clusterTime: clusterTime) {
                    result[number, default: []].append(block)
                }
            case 0x1F43B675, 0x1C53BB6B: return result // bilinmeyen boyutlu kümenin sonu
            default: break
            }
            position = item.dataStart + item.size
        }
        return result
    }

    private func peekTrackNumber(_ element: Element) throws -> UInt64? {
        var start = element.dataStart
        if element.id == 0xA0 {
            // BlockGroup → Block çocuğunu bul.
            let end = element.dataStart + element.size
            while start < end, let child = try header(at: &start) {
                if child.id == 0xA1 { start = child.dataStart; break }
                start = child.dataStart + child.size
            }
        }
        let bytes = try read(at: start, count: 8)
        var reader = BufferReader(data: bytes)
        return reader.vint()
    }

    // MARK: Satırlar

    private func makeCues(_ blocks: [Block], track: Track) -> [SubtitleCue] {
        let scale = Double(timestampScale) / 1_000_000_000
        let isASS = track.codecID.contains("ASS") || track.codecID.contains("SSA")
        let sorted = blocks.sorted { $0.timestamp < $1.timestamp }
        var result: [SubtitleCue] = []
        for (index, block) in sorted.enumerated() {
            guard let payload = decompress(block.payload, track.compression),
                  var text = String(data: payload, encoding: .utf8) ?? String(data: payload, encoding: .windowsCP1254) else { continue }
            let start = Double(block.timestamp) * scale
            var end: Double
            if let duration = block.duration {
                end = start + Double(duration) * scale
            } else if index + 1 < sorted.count {
                end = min(Double(sorted[index + 1].timestamp) * scale, start + 8)
            } else {
                end = start + 4
            }
            var top = false
            if isASS {
                // ReadOrder, Layer, Style, Name, MarginL, MarginR, MarginV, Effect, Text
                let fields = text.split(separator: ",", maxSplits: 8, omittingEmptySubsequences: false)
                guard fields.count == 9 else { continue }
                let raw = String(fields[8])
                if raw.contains(#"\p1"#) { continue }
                top = raw.contains(#"\an8"#) || raw.contains(#"\an7"#) || raw.contains(#"\an9"#)
                text = SubtitleParser.cleanMarkup(
                    raw.replacingOccurrences(of: #"\N"#, with: "\n")
                        .replacingOccurrences(of: #"\n"#, with: "\n")
                        .replacingOccurrences(of: #"\h"#, with: " ")
                )
            } else {
                top = text.contains(#"{\an8}"#)
                text = SubtitleParser.cleanMarkup(text.replacingOccurrences(of: "\r\n", with: "\n"))
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if end <= start { end = start + 2 }
            guard !text.isEmpty else { continue }
            result.append(SubtitleCue(id: result.count, start: start, end: end, text: text, top: top))
        }
        return result
    }

    private func decompress(_ data: Data, _ compression: Track.Compression?) -> Data? {
        switch compression {
        case nil: return data
        case .headerStripping(let prefix): return prefix + data
        case .zlib: return Self.inflateZlib(data)
        }
    }

    /// zlib (2 bayt başlık + DEFLATE) açar.
    static func inflateZlib(_ data: Data) -> Data? {
        guard data.count > 2 else { return nil }
        let deflate = data.dropFirst(2)
        var capacity = max(1024, deflate.count * 8)
        while capacity <= 1 << 22 {
            var output = Data(count: capacity)
            let written = output.withUnsafeMutableBytes { out in
                deflate.withUnsafeBytes { input in
                    compression_decode_buffer(out.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                              input.bindMemory(to: UInt8.self).baseAddress!, deflate.count, nil, COMPRESSION_ZLIB)
                }
            }
            if written > 0, written < capacity { return output.prefix(written) }
            capacity *= 4
        }
        return nil
    }

    // MARK: EBML

    private struct Element {
        let id: UInt32
        let offset: UInt64
        let dataStart: UInt64
        let size: UInt64
        let unknownSize: Bool
    }

    /// `offset`'teki öğenin başlığını okur ve `offset`'i veri başlangıcına taşır.
    private func header(at offset: inout UInt64) throws -> Element? {
        guard offset + 2 <= fileSize else { return nil }
        let header = try read(at: offset, count: Int(min(12, fileSize - offset)))
        var reader = BufferReader(data: header)
        guard let id = reader.elementID(), let (size, unknown) = reader.sizeVint() else { return nil }
        let element = Element(id: id, offset: offset, dataStart: offset + UInt64(reader.position), size: unknown ? 0 : size, unknownSize: unknown)
        offset = element.dataStart
        return element
    }

    private func children(of element: Element) throws -> [Element] {
        guard element.size < 64 << 20 else { return [] }
        let data = try read(element)
        var reader = BufferReader(data: data)
        var result: [Element] = []
        while let child = reader.nextElement() {
            result.append(Element(id: child.id, offset: element.dataStart + UInt64(child.headerStart),
                                  dataStart: element.dataStart + UInt64(child.dataStart), size: UInt64(child.size), unknownSize: false))
            reader.skip(child)
        }
        return result
    }

    private func read(_ element: Element) throws -> Data {
        try read(at: element.dataStart, count: Int(min(element.size, 64 << 20)))
    }

    private func readUInt(_ element: Element) throws -> UInt64 {
        try read(element).reduce(0) { $0 << 8 | UInt64($1) }
    }

    private func readString(_ element: Element) throws -> String {
        let data = try read(element)
        let trimmed = data.prefix { $0 != 0 }
        return String(decoding: trimmed, as: UTF8.self)
    }

    private func read(at offset: UInt64, count: Int) throws -> Data {
        guard count > 0, offset < fileSize else { return Data() }
        try handle.seek(toOffset: offset)
        return try handle.read(upToCount: count) ?? Data()
    }
}

/// Bellekteki EBML verisini okur.
private struct BufferReader {
    struct Child {
        let id: UInt32
        let headerStart: Int
        let dataStart: Int
        let size: Int
    }

    let data: Data
    private(set) var position: Int
    private let end: Int

    init(data: Data) {
        self.data = data
        position = data.startIndex
        end = data.endIndex
    }

    private init(data: Data, start: Int, end: Int) {
        self.data = data
        position = start
        self.end = end
    }

    var remaining: Int { end - position }

    mutating func byte() -> UInt8 {
        guard position < end else { return 0 }
        defer { position += 1 }
        return data[position]
    }

    mutating func elementID() -> UInt32? {
        guard position < end else { return nil }
        let first = data[position]
        let length = first.leadingZeroBitCount + 1
        guard length <= 4, position + length <= end else { return nil }
        var value: UInt32 = 0
        for i in 0..<length { value = value << 8 | UInt32(data[position + i]) }
        position += length
        return value
    }

    /// Boyut vint'i (işaret biti çıkarılmış). Tümü 1 ise boyut bilinmiyor.
    mutating func sizeVint() -> (UInt64, Bool)? {
        guard position < end else { return nil }
        let first = data[position]
        let length = first.leadingZeroBitCount + 1
        guard length <= 8, position + length <= end else { return nil }
        var value = UInt64(first) & ((1 << (8 - UInt64(length))) - 1)
        var allOnes = value == (1 << (8 - UInt64(length))) - 1
        for i in 1..<length {
            let byte = data[position + i]
            value = value << 8 | UInt64(byte)
            if byte != 0xFF { allOnes = false }
        }
        position += length
        return (value, allOnes)
    }

    mutating func vint() -> UInt64? { sizeVint()?.0 }

    mutating func nextElement() -> Child? {
        let start = position
        guard let id = elementID(), let (size, unknown) = sizeVint(), !unknown else { return nil }
        let dataStart = position
        guard dataStart + Int(size) <= end else { return nil }
        position = start
        return Child(id: id, headerStart: start - data.startIndex, dataStart: dataStart - data.startIndex, size: Int(size))
    }

    mutating func skip(_ child: Child) {
        position = data.startIndex + child.dataStart + child.size
    }

    func sub(_ child: Child) -> BufferReader {
        BufferReader(data: data, start: data.startIndex + child.dataStart, end: data.startIndex + child.dataStart + child.size)
    }

    func uint(_ child: Child) -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<child.size { value = value << 8 | UInt64(data[data.startIndex + child.dataStart + i]) }
        return value
    }

    func rest() -> Data {
        data.subdata(in: position..<end)
    }
}
