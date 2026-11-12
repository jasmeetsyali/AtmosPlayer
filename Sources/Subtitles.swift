import Foundation

// Text subtitles (SRT-style S_TEXT/UTF8 and ASS/SSA) collected while demuxing.

struct SubtitleCue {
    var start: Double      // seconds
    var end: Double
    var text: String
    var italic: Bool
}

enum SubtitleText {
    static let supported: Set<String> = ["S_TEXT/UTF8", "S_TEXT/ASS", "S_TEXT/SSA", "S_TEXT/WEBVTT"]

    /// Turns one subtitle block into display text.
    static func clean(_ data: Data, codec: String) -> (String, Bool) {
        var t = String(decoding: data, as: UTF8.self)
        if codec == "S_TEXT/ASS" || codec == "S_TEXT/SSA" {
            // ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect,Text
            var commas = 0
            if let idx = t.firstIndex(where: { c in if c == "," { commas += 1 }; return commas == 8 }) {
                t = String(t[t.index(after: idx)...])
            }
            let italic = t.contains("\\i1")
            t = t.replacingOccurrences(of: "\\{[^}]*\\}", with: "", options: .regularExpression)
            t = t.replacingOccurrences(of: "\\N", with: "\n").replacingOccurrences(of: "\\n", with: "\n")
                 .replacingOccurrences(of: "\\h", with: " ")
            return (t.trimmingCharacters(in: .whitespacesAndNewlines), italic)
        }
        let italic = t.range(of: "<i>", options: .caseInsensitive) != nil
        t = t.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "{\\\\an\\d}", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<")
             .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "\r", with: "")
        return (t.trimmingCharacters(in: .whitespacesAndNewlines), italic)
    }
}

final class SubtitleStore {
    private let lock = NSLock()
    private var cues: [SubtitleCue] = []      // sorted by start

    func clear() { lock.lock(); cues.removeAll(); lock.unlock() }

    func add(_ c: SubtitleCue) {
        guard !c.text.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        // binary search insert position; skip duplicates after re-reading the same cluster
        var lo = 0, hi = cues.count
        while lo < hi { let m = (lo + hi) / 2; if cues[m].start < c.start { lo = m + 1 } else { hi = m } }
        if lo < cues.count, abs(cues[lo].start - c.start) < 0.001, cues[lo].text == c.text { return }
        cues.insert(c, at: lo)
        // A cue with no duration ends when the next one starts (max 5 s).
        if lo > 0, cues[lo - 1].end > c.start, cues[lo - 1].end - cues[lo - 1].start == 5 { cues[lo - 1].end = c.start }
    }

    /// All cues showing at time t, joined (overlapping lines stack).
    func cue(at t: Double) -> SubtitleCue? {
        lock.lock(); defer { lock.unlock() }
        var lo = 0, hi = cues.count
        while lo < hi { let m = (lo + hi) / 2; if cues[m].start <= t { lo = m + 1 } else { hi = m } }
        var active: [SubtitleCue] = []
        var i = lo - 1
        while i >= 0 && t - cues[i].start < 30 {
            if cues[i].end > t { active.insert(cues[i], at: 0) }
            i -= 1
        }
        guard let first = active.first else { return nil }
        return SubtitleCue(start: first.start, end: first.end, text: active.map(\.text).joined(separator: "\n"),
                           italic: active.allSatisfy(\.italic))
    }
}

func subsTest(_ path: String, start: Double) throws {
    let mkv = try MKVFile(path: path)
    guard let t = mkv.tracks.first(where: { SubtitleText.supported.contains($0.codecID) }) else { print("no text subtitles"); return }
    print("Track #\(t.number) \(t.codecID) [\(t.language)] \(t.name)")
    var n = 0
    let startNs = Int64(start * 1e9)
    mkv.readPackets(from: mkv.clusterOffset(for: startNs), tracks: [t.number]) { pkt in
        if pkt.pts < startNs { return true }
        let (text, it) = SubtitleText.clean(pkt.data, codec: t.codecID)
        print(String(format: "%.2f +%.2fs%@: %@", Double(pkt.pts) / 1e9, Double(pkt.duration) / 1e9,
                     it ? " (i)" : "", text.replacingOccurrences(of: "\n", with: " / ")))
        n += 1
        return n < 6
    }
}
