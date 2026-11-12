import Foundation

// Locates and parses EMDF containers (ETSI TS 102 366 Annex H) inside E-AC-3 frames.
// Dolby Atmos in DD+ carries its object metadata (OAMD, payload id 11) and
// joint object coding parameters (JOC, payload id 14) in EMDF payloads.

struct BitReader {
    let bytes: [UInt8]
    var pos: Int            // bit position
    init(_ b: [UInt8], bit: Int = 0) { bytes = b; pos = bit }
    var remaining: Int { bytes.count * 8 - pos }
    mutating func read(_ n: Int) -> Int {
        var v = 0
        for _ in 0..<n {
            guard pos < bytes.count * 8 else { return v << 1 }
            v = (v << 1) | Int((bytes[pos >> 3] >> (7 - UInt8(pos & 7))) & 1)
            pos += 1
        }
        return v
    }
    mutating func variableBits(_ n: Int) -> Int {
        var value = 0
        while true {
            value += read(n)
            if read(1) == 0 { break }
            value <<= n
            value += 1 << n
            if remaining <= 0 { break }
        }
        return value
    }
}

struct EMDFPayload {
    var id: Int
    var bitOffset: Int      // within frame
    var size: Int           // bytes
}

struct EMDFContainer {
    var syncBit: Int
    var length: Int
    var version: Int
    var keyID: Int
    var payloads: [EMDFPayload]
    var protectionPrimaryBits: Int
    var protectionSecondaryBits: Int
    var protectionBit = 0     // first bit of protection_bits_primary within the frame
}

enum EMDF {
    static func find(in frame: [UInt8]) -> [EMDFContainer] {
        var found: [EMDFContainer] = []
        let totalBits = frame.count * 8
        var bit = 0
        while bit + 32 < totalBits {
            var r = BitReader(frame, bit: bit)
            if r.read(16) == 0x5838 {
                let len = r.read(16)
                let start = r.pos
                if len > 0 && start + len * 8 <= totalBits, var c = parse(frame, at: start, length: len) {
                    c.syncBit = bit
                    found.append(c)
                    bit = start + len * 8
                    continue
                }
            }
            bit += 1
        }
        return found
    }

    static func parse(_ frame: [UInt8], at start: Int, length: Int) -> EMDFContainer? {
        var r = BitReader(frame, bit: start)
        let end = start + length * 8
        var version = r.read(2)
        if version == 3 { version += r.variableBits(2) }
        var key = r.read(3)
        if key == 7 { key += r.variableBits(3) }
        var payloads: [EMDFPayload] = []
        while r.pos < end {
            var id = r.read(5)
            if id == 0 { break }
            if id == 0x1F { id += r.variableBits(5) }
            // emdf_payload_config
            let smploffste = r.read(1)
            if smploffste == 1 { _ = r.read(11); _ = r.read(1) }
            if r.read(1) == 1 { _ = r.variableBits(11) }      // duration
            if r.read(1) == 1 { _ = r.variableBits(2) }       // groupid
            if r.read(1) == 1 { _ = r.read(8) }               // codecdata
            let discard = r.read(1)
            if discard == 0 {
                var aligned = 0
                if smploffste == 0 {
                    aligned = r.read(1)
                    if aligned == 1 { _ = r.read(1); _ = r.read(1) }
                }
                if smploffste == 1 || aligned == 1 { _ = r.read(5); _ = r.read(2) }
            }
            let size = r.variableBits(8)
            if r.pos + size * 8 > end { return nil }
            payloads.append(EMDFPayload(id: id, bitOffset: r.pos, size: size))
            r.pos += size * 8
        }
        let lens = [0, 8, 32, 128]
        let p1 = lens[r.read(2)], p2 = lens[r.read(2)]
        return EMDFContainer(syncBit: 0, length: length, version: version, keyID: key, payloads: payloads,
                             protectionPrimaryBits: p1, protectionSecondaryBits: p2, protectionBit: r.pos)
    }
}

// MARK: Frame editing

extension Array where Element == UInt8 {
    mutating func flipBits(at bit: Int, count: Int) {
        for b in bit..<(bit + count) { self[b >> 3] ^= UInt8(0x80 >> (b & 7)) }
    }
}

enum EAC3Edit {
    /// CRC-16 (x^16 + x^15 + x^2 + 1) as used for E-AC-3 crc2.
    static func crc16(_ d: ArraySlice<UInt8>) -> UInt16 {
        var r: UInt16 = 0
        for b in d {
            r ^= UInt16(b) << 8
            for _ in 0..<8 { r = (r & 0x8000) != 0 ? (r << 1) ^ 0x8005 : r << 1 }
        }
        return r
    }

    /// Rewrites the frame's trailing crc2 after an edit.
    static func fixCRC(_ f: inout [UInt8]) {
        let c = crc16(f[2..<(f.count - 2)])
        f[f.count - 2] = UInt8(c >> 8)
        f[f.count - 1] = UInt8(c & 0xFF)
    }

    /// Test only: breaks the EMDF protection value to see whether the decoder verifies it.
    static func breakProtection(_ f: inout [UInt8]) -> Bool {
        guard let c = EMDF.find(in: f).first, c.protectionPrimaryBits > 0 else { return false }
        f.flipBits(at: c.protectionBit, count: c.protectionPrimaryBits)
        fixCRC(&f)
        return true
    }

    /// Applies `edit` to every sync frame in a packet and returns the rebuilt packet.
    static func editPacket(_ d: Data, _ edit: (inout [UInt8]) -> Void) -> Data {
        var out = Data(capacity: d.count)
        for fr in EAC3.split(d) {
            var bytes = [UInt8](d.subdata(in: fr.offset..<(fr.offset + fr.bytes)))
            edit(&bytes)
            out.append(contentsOf: bytes)
        }
        return out
    }
}

func emdfProbe(_ path: String, start: Double, frames: Int) throws {
    let mkv = try MKVFile(path: path)
    guard let a = mkv.tracks.first(where: { $0.codecID == "A_EAC3" && $0.name.localizedCaseInsensitiveContains("atmos") }) else { return }
    var n = 0
    let startNs = Int64(start * 1e9)
    mkv.readPackets(from: mkv.clusterOffset(for: startNs), tracks: [a.number]) { pkt in
        if pkt.pts < startNs { return true }
        for f in EAC3.split(pkt.data) {
            let bytes = [UInt8](pkt.data.subdata(in: f.offset..<(f.offset + f.bytes)))
            let cs = EMDF.find(in: bytes)
            let desc = cs.map { c in
                "EMDF@bit\(c.syncBit) len=\(c.length) v\(c.version) key=\(c.keyID) prot=\(c.protectionPrimaryBits)/\(c.protectionSecondaryBits) payloads=" +
                c.payloads.map { "id\($0.id):\($0.size)B" }.joined(separator: ",")
            }
            if let dir = ProcessInfo.processInfo.environment["DUMP_DIR"] {
                try? Data(bytes).write(to: URL(fileURLWithPath: "\(dir)/f\(n).bin"))
            }
            print("frame \(n) \(f.bytes)B: " + (desc.isEmpty ? "no EMDF" : desc.joined(separator: " | ")))
            n += 1
        }
        return n < frames
    }
}
