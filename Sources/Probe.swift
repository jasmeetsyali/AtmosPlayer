import Foundation

func probe(_ path: String) throws {
    let mkv = try MKVFile(path: path)
    print(String(format: "Duration: %.1f s, timescale %llu, cues %d", mkv.duration, mkv.timescale, mkv.cues.count))
    for t in mkv.tracks {
        print("#\(t.number) type=\(t.type) \(t.codecID) lang=\(t.language) name=\"\(t.name)\" " +
              "\(t.width)x\(t.height) \(t.sampleRate)Hz ch=\(t.channels) priv=\(t.codecPrivate.count)B " +
              "strip=\(t.stripHeader.count)B colour=\(t.primaries)/\(t.transfer)/\(t.matrix)")
    }
    guard let a = mkv.tracks.first(where: { $0.codecID == "A_EAC3" }) else { return }
    var n = 0
    mkv.readPackets(from: mkv.firstCluster, tracks: [a.number]) { pkt in
        let frames = EAC3.split(pkt.data)
        let desc = frames.map { "[\($0.independent ? "I" : "D")\($0.substream) \($0.blocks)blk \($0.bytes)B]" }
        print(String(format: "pts %.3f  %dB ", Double(pkt.pts) / 1e9, pkt.data.count) + desc.joined())
        n += 1
        return n < 8
    }
}

/// Decodes a few seconds of the first E-AC-3 track and prints per-channel levels.
func decodeTest(_ path: String, start: Double) throws {
    let mkv = try MKVFile(path: path)
    guard let a = mkv.tracks.first(where: { $0.codecID == "A_EAC3" }) else { return }
    let dec = try EAC3Decoder()
    var sums = [Double](repeating: 0, count: 6)
    var total = 0
    let startNs = Int64(start * 1e9)
    mkv.readPackets(from: mkv.clusterOffset(for: startNs), tracks: [a.number]) { pkt in
        if pkt.pts < startNs { return true }
        for f in EAC3.split(pkt.data) where f.independent {
            dec.decode(pkt.data.subdata(in: f.offset..<(f.offset + f.bytes))) { buf, n in
                for i in 0..<n { for c in 0..<6 { let v = Double(buf[i * 6 + c]); sums[c] += v * v } }
                total += n
            }
        }
        return total < 48000 * 5
    }
    let names = ["L", "R", "C", "LFE", "Ls", "Rs"]
    print("decoded \(total) frames")
    for c in 0..<6 { print(String(format: "%-4@ %6.1f dBFS", names[c] as NSString, 10 * log10(max(1e-12, sums[c] / Double(max(total, 1)))))) }
}
