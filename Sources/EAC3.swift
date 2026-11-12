import Foundation

// Dolby Digital Plus (E-AC-3) frame parsing and IEC 61937 packing for HDMI bitstreaming.

struct EAC3Frame {
    var offset: Int
    var bytes: Int
    var independent: Bool
    var substream: Int
    var blocks: Int
}

enum EAC3 {
    static let blocksForCode = [1, 2, 3, 6]

    /// Splits a packet into E-AC-3 sync frames.
    static func split(_ d: Data) -> [EAC3Frame] {
        var out: [EAC3Frame] = []
        d.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let b = raw.bindMemory(to: UInt8.self)
            var p = 0
            while p + 6 <= b.count {
                guard b[p] == 0x0B && b[p + 1] == 0x77 else { p += 1; continue }
                let bsid = Int(b[p + 5] >> 3)
                guard bsid > 10 && bsid <= 16 else { break }   // plain AC-3 not handled here
                let strmtyp = Int(b[p + 2] >> 6)
                let substream = Int((b[p + 2] >> 3) & 7)
                let frmsiz = (Int(b[p + 2] & 7) << 8) | Int(b[p + 3])
                let bytes = (frmsiz + 1) * 2
                let fscod = Int(b[p + 4] >> 6)
                let blocks = fscod == 3 ? 6 : blocksForCode[Int((b[p + 4] >> 4) & 3)]
                if p + bytes > b.count { break }
                out.append(EAC3Frame(offset: p, bytes: bytes, independent: strmtyp != 1,
                                     substream: substream, blocks: blocks))
                p += bytes
            }
        }
        return out
    }
}

/// Packs E-AC-3 frames into IEC 61937 bursts (24576 bytes = 6144 frames of 2ch 16-bit at 192 kHz).
/// Each burst carries 1536 audio samples (32 ms at 48 kHz).
final class IEC61937Packer {
    static let burstBytes = 24576
    private var pending = Data()
    private var blocks = 0
    private var pendingPTS: Int64 = 0

    /// Feeds one demuxed packet. Returns completed bursts with the pts of their first frame.
    func feed(_ pkt: Data, pts: Int64) -> [(Data, Int64)] {
        var out: [(Data, Int64)] = []
        for f in EAC3.split(pkt) {
            if f.independent && f.substream == 0 && blocks >= 6 {
                out.append((makeBurst(), pendingPTS))
                pending.removeAll(keepingCapacity: true)
                blocks = 0
            }
            if pending.isEmpty { pendingPTS = pts }
            pending.append(pkt.subdata(in: f.offset..<(f.offset + f.bytes)))
            if f.independent && f.substream == 0 { blocks += f.blocks }
        }
        return out
    }

    func reset() { pending.removeAll(); blocks = 0 }

    private func makeBurst() -> Data {
        var burst = Data(count: IEC61937Packer.burstBytes)
        let payload = pending.count
        burst.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            let w = raw.bindMemory(to: UInt16.self)
            w[0] = UInt16(0xF872).littleEndian
            w[1] = UInt16(0x4E1F).littleEndian
            w[2] = UInt16(21).littleEndian            // data type 21 = E-AC-3
            w[3] = UInt16(truncatingIfNeeded: payload).littleEndian   // length in bytes
            let o = raw.bindMemory(to: UInt8.self)
            pending.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
                let s = src.bindMemory(to: UInt8.self)
                let maxBytes = min(payload, IEC61937Packer.burstBytes - 8)
                var i = 0
                // byte-swap into little-endian 16-bit words
                while i < maxBytes {
                    o[8 + i] = i + 1 < maxBytes ? s[i + 1] : 0
                    o[8 + i + 1] = s[i]
                    i += 2
                }
            }
        }
        return burst
    }
}
