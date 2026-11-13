import Foundation

let args = CommandLine.arguments
let cliCommands: Set<String> = ["probe", "formats", "audiotest", "decodetest", "emdf", "subs"]
if args.count < 2 || !cliCommands.contains(args[1]) {
    runApp()
    exit(0)
}

func audioTest(_ path: String, start: Double, length: Double) throws {
    let mkv = try MKVFile(path: path)
    let tracks = mkv.tracks.filter { $0.codecID == "A_EAC3" }
    guard let track = tracks.first(where: { $0.name.localizedCaseInsensitiveContains("atmos") }) ?? tracks.first else {
        print("no E-AC-3 track"); return
    }
    print("Track #\(track.number) \"\(track.name)\" [\(track.language)]")
    let out = try HDMIBitstreamOutput()
    print("Device: \(out.deviceLabel)")
    try out.start()
    print(String(format: "Bitstreaming E-AC-3 over HDMI (latency %.0f ms). Ctrl-C to stop.", out.latencySeconds * 1000))

    let stopSrc = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    signal(SIGINT, SIG_IGN)
    stopSrc.setEventHandler { out.restore(); print("\nRestored audio device."); exit(0) }
    stopSrc.resume()

    let startNs = Int64(start * 1e9)
    let endNs = Int64((start + length) * 1e9)
    DispatchQueue.global(qos: .userInitiated).async {
        let packer = IEC61937Packer()
        mkv.readPackets(from: mkv.clusterOffset(for: startNs), tracks: [track.number]) { pkt in
            if pkt.pts < startNs { return true }
            for (burst, _) in packer.feed(pkt.data, pts: pkt.pts) {
                if !out.fifo.write(burst, generation: 0, current: { 0 }) { return false }
            }
            return pkt.pts < endNs
        }
        while out.fifo.count > 0 { usleep(50_000) }
        usleep(UInt32(out.latencySeconds * 1e6) + 200_000)
        out.restore()
        print("Done, restored audio device.")
        exit(0)
    }
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now() + 1, repeating: 1)
    timer.setEventHandler { print(String(format: "  %.1f s", start + out.playedSeconds)) }
    timer.resume()
    dispatchMain()
}

do {
    switch args[1] {
    case "probe": try probe(args[2])
    case "decodetest": try decodeTest(args[2], start: args.count > 3 ? Double(args[3]) ?? 600 : 600)
    case "emdf": try emdfProbe(args[2], start: args.count > 3 ? Double(args[3]) ?? 600 : 600, frames: 6)
    case "subs": try subsTest(args[2], start: args.count > 3 ? Double(args[3]) ?? 600 : 600)
    case "formats":
        let out = try HDMIBitstreamOutput()
        print("\(out.deviceLabel): \(out.availableFormats().joined(separator: ", "))")
    case "audiotest":
        try audioTest(args[2], start: args.count > 3 ? Double(args[3]) ?? 0 : 0,
                      length: args.count > 4 ? Double(args[4]) ?? 60 : 60)
    default: print("unknown command \(args[1])")
    }
} catch {
    print("error: \(error)")
    exit(1)
}
