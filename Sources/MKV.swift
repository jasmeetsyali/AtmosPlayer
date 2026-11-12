import Foundation

// Minimal Matroska (MKV) demuxer over a memory-mapped file.

enum MKVError: Error { case open(String), parse(String) }

struct MKVTrack {
    var number: UInt64 = 0
    var type: UInt64 = 0          // 1 video, 2 audio, 17 subtitle
    var codecID = ""
    var codecPrivate = Data()
    var language = "und"
    var name = ""
    var width: UInt64 = 0
    var height: UInt64 = 0
    var sampleRate: Double = 0
    var channels: UInt64 = 0
    var defaultDuration: UInt64 = 0
    var stripHeader = Data()      // ContentCompAlgo 3 (header stripping)
    // Colour metadata
    var matrix: UInt64 = 2, transfer: UInt64 = 2, primaries: UInt64 = 2, range: UInt64 = 0
}

struct MKVPacket {
    var track: UInt64
    var pts: Int64        // nanoseconds
    var keyframe: Bool
    var data: Data
    var duration: Int64 = 0   // nanoseconds, from BlockDuration (subtitles); 0 if unknown
}

struct CuePoint { var time: Int64; var clusterPos: UInt64 }   // time in ns, pos relative to segment data

final class MKVFile {
    let base: UnsafePointer<UInt8>
    let size: Int
    private let fd: Int32
    var tracks: [MKVTrack] = []
    var timescale: UInt64 = 1_000_000
    var duration: Double = 0      // seconds
    var segmentStart = 0
    var segmentEnd = 0
    var firstCluster = 0
    var cues: [CuePoint] = []

    init(path: String) throws {
        fd = open(path, O_RDONLY)
        if fd < 0 { throw MKVError.open("cannot open \(path)") }
        var st = stat()
        fstat(fd, &st)
        size = Int(st.st_size)
        guard let p = mmap(nil, size, PROT_READ, MAP_PRIVATE, fd, 0), p != MAP_FAILED else {
            throw MKVError.open("mmap failed")
        }
        madvise(p, size, MADV_SEQUENTIAL)
        base = UnsafePointer(p.assumingMemoryBound(to: UInt8.self))
        try parseHeader()
    }

    deinit {
        munmap(UnsafeMutableRawPointer(mutating: base), size)
        close(fd)
    }

    // MARK: EBML primitives

    func readID(_ pos: inout Int) -> UInt32? {
        guard pos < size else { return nil }
        let b = base[pos]
        var len = 1
        var mask: UInt8 = 0x80
        while len <= 4 && (b & mask) == 0 { mask >>= 1; len += 1 }
        if len > 4 || pos + len > size { return nil }
        var v: UInt32 = 0
        for i in 0..<len { v = (v << 8) | UInt32(base[pos + i]) }
        pos += len
        return v
    }

    /// Returns nil for unknown size.
    func readSize(_ pos: inout Int) -> UInt64?? {
        guard pos < size else { return .none }
        let b = base[pos]
        var len = 1
        var mask: UInt8 = 0x80
        while len <= 8 && (b & mask) == 0 { mask >>= 1; len += 1 }
        if len > 8 || pos + len > size { return .none }
        var v = UInt64(b & (mask &- 1))
        var allOnes = v == UInt64(mask &- 1)
        for i in 1..<len {
            let byte = base[pos + i]
            if byte != 0xFF { allOnes = false }
            v = (v << 8) | UInt64(byte)
        }
        pos += len
        return .some(allOnes ? nil : v)
    }

    func uint(_ pos: Int, _ len: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<min(len, 8) { v = (v << 8) | UInt64(base[pos + i]) }
        return v
    }

    func float(_ pos: Int, _ len: Int) -> Double {
        if len == 4 { return Double(Float(bitPattern: UInt32(uint(pos, 4)))) }
        if len == 8 { return Double(bitPattern: uint(pos, 8)) }
        return 0
    }

    func string(_ pos: Int, _ len: Int) -> String {
        let d = Data(bytes: base + pos, count: len)
        return String(decoding: d.prefix { $0 != 0 }, as: UTF8.self)
    }

    func data(_ pos: Int, _ len: Int) -> Data { Data(bytes: base + pos, count: len) }

    /// Iterate children of [start, end).
    func children(_ start: Int, _ end: Int, _ body: (UInt32, Int, Int) throws -> Void) rethrows {
        var p = start
        while p < end {
            guard let id = readID(&p), let sz = readSize(&p) else { return }
            let len = sz.map { Int($0) } ?? (end - p)
            let e = min(p + len, end)
            try body(id, p, e - p)
            p = e
        }
    }

    // MARK: Header

    private func parseHeader() throws {
        var p = 0
        // EBML header
        guard let id = readID(&p), id == 0x1A45DFA3, let s = readSize(&p), let hs = s else {
            throw MKVError.parse("not a Matroska file")
        }
        p += Int(hs)
        guard let sid = readID(&p), sid == 0x18538067, let ss = readSize(&p) else {
            throw MKVError.parse("no Segment")
        }
        segmentStart = p
        segmentEnd = ss.map { p + Int($0) } ?? size
        segmentEnd = min(segmentEnd, size)

        var cuesPos: Int? = nil
        var q = segmentStart
        while q < segmentEnd {
            let elemStart = q
            guard let id = readID(&q), let sz = readSize(&q) else { break }
            if id == 0x1F43B675 { firstCluster = elemStart; break }
            let len = sz.map { Int($0) } ?? 0
            switch id {
            case 0x114D9B74: // SeekHead
                children(q, q + len) { id, p, l in
                    guard id == 0x4DBB else { return }
                    var sid: UInt64 = 0, spos: UInt64 = 0
                    children(p, p + l) { id, p, l in
                        if id == 0x53AB { sid = uint(p, l) }
                        if id == 0x53AC { spos = uint(p, l) }
                    }
                    if sid == 0x1C53BB6B { cuesPos = segmentStart + Int(spos) }
                }
            case 0x1549A966: parseInfo(q, len)
            case 0x1654AE6B: parseTracks(q, len)
            case 0x1C53BB6B: parseCues(q, len)
            default: break
            }
            q += len
        }
        if firstCluster == 0 { throw MKVError.parse("no clusters") }
        if cues.isEmpty, let cp = cuesPos, cp < size {
            var r = cp
            if let id = readID(&r), id == 0x1C53BB6B, let sz = readSize(&r), let l = sz {
                parseCues(r, Int(l))
            }
        }
    }

    private func parseInfo(_ p: Int, _ len: Int) {
        var dur = 0.0
        children(p, p + len) { id, p, l in
            if id == 0x2AD7B1 { timescale = uint(p, l) }
            if id == 0x4489 { dur = float(p, l) }
        }
        duration = dur * Double(timescale) / 1e9
    }

    private func parseTracks(_ p: Int, _ len: Int) {
        children(p, p + len) { id, p, l in
            guard id == 0xAE else { return }
            var t = MKVTrack()
            children(p, p + l) { id, p, l in
                switch id {
                case 0xD7: t.number = uint(p, l)
                case 0x83: t.type = uint(p, l)
                case 0x86: t.codecID = string(p, l)
                case 0x63A2: t.codecPrivate = data(p, l)
                case 0x22B59C: t.language = string(p, l)
                case 0x22B59D: t.language = string(p, l)
                case 0x536E: t.name = string(p, l)
                case 0x23E383: t.defaultDuration = uint(p, l)
                case 0xE0:
                    children(p, p + l) { id, p, l in
                        if id == 0xB0 { t.width = uint(p, l) }
                        if id == 0xBA { t.height = uint(p, l) }
                        if id == 0x55B0 {
                            children(p, p + l) { id, p, l in
                                switch id {
                                case 0x55B1: t.matrix = uint(p, l)
                                case 0x55BA: t.transfer = uint(p, l)
                                case 0x55BB: t.primaries = uint(p, l)
                                case 0x55B9: t.range = uint(p, l)
                                default: break
                                }
                            }
                        }
                    }
                case 0xE1:
                    children(p, p + l) { id, p, l in
                        if id == 0xB5 { t.sampleRate = float(p, l) }
                        if id == 0x9F { t.channels = uint(p, l) }
                    }
                case 0x6D80:
                    children(p, p + l) { id, p, l in
                        guard id == 0x6240 else { return }
                        children(p, p + l) { id, p, l in
                            guard id == 0x5034 else { return }
                            var algo: UInt64 = 0
                            var settings = Data()
                            children(p, p + l) { id, p, l in
                                if id == 0x4254 { algo = uint(p, l) }
                                if id == 0x4255 { settings = data(p, l) }
                            }
                            if algo == 3 { t.stripHeader = settings }
                        }
                    }
                default: break
                }
            }
            tracks.append(t)
        }
    }

    private func parseCues(_ p: Int, _ len: Int) {
        children(p, p + len) { id, p, l in
            guard id == 0xBB else { return }
            var time: UInt64 = 0
            var pos: UInt64? = nil
            children(p, p + l) { id, p, l in
                if id == 0xB3 { time = uint(p, l) }
                if id == 0xB7 && pos == nil {
                    children(p, p + l) { id, p, l in
                        if id == 0xF1 { pos = uint(p, l) }
                    }
                }
            }
            if let pos { cues.append(CuePoint(time: Int64(time * timescale), clusterPos: pos)) }
        }
        cues.sort { $0.time < $1.time }
    }

    // MARK: Packet reading

    /// File offset of the cluster to start from for a seek to `ns`.
    func clusterOffset(for ns: Int64) -> Int {
        guard !cues.isEmpty else { return firstCluster }
        var lo = 0, hi = cues.count - 1, best = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if cues[mid].time <= ns { best = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return segmentStart + Int(cues[best].clusterPos)
    }

    /// Reads packets from `offset` (a cluster start) for the given track numbers.
    /// The callback returns false to stop.
    func readPackets(from offset: Int, tracks wanted: Set<UInt64>,
                     _ body: (MKVPacket) -> Bool) {
        let strip = Dictionary(uniqueKeysWithValues: tracks.map { ($0.number, $0.stripHeader) })
        var p = offset
        while p < segmentEnd {
            guard let id = readID(&p), let sz = readSize(&p) else { return }
            if id != 0x1F43B675 {
                guard let l = sz else { continue }   // unknown-size non-cluster: descend
                p += Int(l)
                continue
            }
            let end = sz.map { min(p + Int($0), segmentEnd) } ?? segmentEnd
            var clusterTime: UInt64 = 0
            var q = p
            var stop = false
            while q < end {
                let elemStart = q
                guard let cid = readID(&q), let csz = readSize(&q) else { stop = true; break }
                if sz == nil && (cid == 0x1F43B675 || cid == 0x1C53BB6B) { q = elemStart; break }
                let clen = csz.map { Int($0) } ?? 0
                switch cid {
                case 0xE7: clusterTime = uint(q, clen)
                case 0xA3:
                    if !block(q, clen, clusterTime, simple: true, wanted, strip, body) { stop = true }
                case 0xA0:
                    var blockPos = 0, blockLen = 0
                    var dur: UInt64 = 0
                    children(q, q + clen) { bid, bp, bl in
                        if bid == 0xA1 { blockPos = bp; blockLen = bl }
                        if bid == 0x9B { dur = uint(bp, bl) }
                    }
                    if blockLen > 0 && !block(blockPos, blockLen, clusterTime, simple: false, wanted, strip,
                                              duration: Int64(dur * timescale), body) { stop = true }
                default: break
                }
                if stop { return }
                q += clen
            }
            p = q > end ? end : (sz == nil ? q : end)
        }
    }

    private func block(_ p: Int, _ len: Int, _ clusterTime: UInt64, simple: Bool,
                       _ wanted: Set<UInt64>, _ strip: [UInt64: Data], duration: Int64 = 0,
                       _ body: (MKVPacket) -> Bool) -> Bool {
        var q = p
        let end = p + len
        // track number vint
        let b = base[q]
        var tl = 1
        var mask: UInt8 = 0x80
        while tl <= 8 && (b & mask) == 0 { mask >>= 1; tl += 1 }
        var track = UInt64(b & (mask &- 1))
        for i in 1..<tl { track = (track << 8) | UInt64(base[q + i]) }
        q += tl
        guard wanted.contains(track) else { return true }
        let rel = Int16(bitPattern: UInt16(base[q]) << 8 | UInt16(base[q + 1]))
        q += 2
        let flags = base[q]
        q += 1
        let key = simple ? (flags & 0x80) != 0 : true
        let pts = (Int64(clusterTime) + Int64(rel)) * Int64(timescale)
        let prefix = strip[track] ?? Data()

        func emit(_ s: Int, _ l: Int) -> Bool {
            var d = prefix
            d.append(base + s, count: l)
            return body(MKVPacket(track: track, pts: pts, keyframe: key, data: d, duration: duration))
        }

        let lacing = (flags >> 1) & 3
        if lacing == 0 { return emit(q, end - q) }

        let count = Int(base[q]) + 1
        q += 1
        var sizes = [Int](repeating: 0, count: count)
        switch lacing {
        case 1: // Xiph
            for i in 0..<(count - 1) {
                var s = 0
                while true { let v = Int(base[q]); q += 1; s += v; if v != 255 { break } }
                sizes[i] = s
            }
        case 3: // EBML
            var r = q
            guard let first = readSize(&r), let f = first else { return true }
            sizes[0] = Int(f)
            for i in 1..<(count - 1) {
                let b0 = base[r]
                var l = 1
                var m: UInt8 = 0x80
                while l <= 8 && (b0 & m) == 0 { m >>= 1; l += 1 }
                var v = Int64(b0 & (m &- 1))
                for k in 1..<l { v = (v << 8) | Int64(base[r + k]) }
                r += l
                let bias = (Int64(1) << (7 * l - 1)) - 1
                sizes[i] = sizes[i - 1] + Int(v - bias)
            }
            q = r
        default: // fixed
            let each = (end - q) / count
            for i in 0..<count { sizes[i] = each }
        }
        if lacing != 2 {
            sizes[count - 1] = end - q - sizes[0..<(count - 1)].reduce(0, +)
        }
        for s in sizes {
            if s < 0 || q + s > end { return true }
            if !emit(q, s) { return false }
            q += s
        }
        return true
    }
}
