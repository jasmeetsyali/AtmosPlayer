import Foundation
import AVFoundation
import CoreMedia

// Playback engine: one reader thread demuxes video + the chosen E-AC-3 track.
// Audio is bitstreamed over HDMI and is the master clock; the video layer's
// timebase runs on the HDMI device's own clock and is aligned to the audio position.

final class Player {
    let mkv: MKVFile
    let videoTrack: MKVTrack
    private(set) var audioTracks: [MKVTrack]
    private(set) var audioIndex: Int
    let out: HDMIBitstreamOutput
    let layer = AVSampleBufferDisplayLayer()
    private let timebase: CMTimebase
    private let formatDesc: CMVideoFormatDescription

    private let stateLock = NSLock()
    private var generation = 0
    private var basePTS: Double = 0          // pts (s) of first burst after the last seek
    private var haveBase = false
    private(set) var paused = false
    private var seekTarget: Double = 0
    var onError: ((String) -> Void)?
    /// Extra delay for the soundbar's own decoding, applied to the picture (seconds).
    var soundDelay: Double = 0.05
    /// Rear Boost in dB. 0 = untouched Dolby Atmos bitstream; > 0 = decoded 5.1 PCM with louder rears.
    private(set) var rearBoostDB: Double = 0
    private var rearGain: Float = 1

    let subtitleTracks: [MKVTrack]
    private(set) var subtitleIndex: Int?          // nil = off
    let subtitles = SubtitleStore()

    var duration: Double { mkv.duration }
    var audioTrack: MKVTrack { audioTracks[audioIndex] }

    init(path: String) throws {
        mkv = try MKVFile(path: path)
        guard let v = mkv.tracks.first(where: { $0.type == 1 && ($0.codecID == "V_MPEGH/ISO/HEVC") }) else {
            throw MKVError.parse("no HEVC video track (only HEVC is supported)")
        }
        videoTrack = v
        audioTracks = mkv.tracks.filter { $0.codecID == "A_EAC3" }
        guard !audioTracks.isEmpty else { throw MKVError.parse("no Dolby Digital Plus (E-AC-3) audio track") }
        audioIndex = audioTracks.firstIndex { $0.name.localizedCaseInsensitiveContains("atmos") } ?? 0
        subtitleTracks = mkv.tracks.filter { $0.type == 17 && SubtitleText.supported.contains($0.codecID) }

        out = try HDMIBitstreamOutput()
        try out.start()

        var clock: CMClock?
        if CMAudioDeviceClockCreateFromAudioDeviceID(allocator: kCFAllocatorDefault, deviceID: out.device, clockOut: &clock) != noErr {
            clock = CMClockGetHostTimeClock()
        }
        var tb: CMTimebase?
        CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: clock!, timebaseOut: &tb)
        timebase = tb!
        CMTimebaseSetRate(timebase, rate: 0)
        layer.controlTimebase = timebase
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)

        var ext: [CFString: Any] = [
            kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: ["hvcC": v.codecPrivate] as CFDictionary,
        ]
        if v.primaries == 9 { ext[kCMFormatDescriptionExtension_ColorPrimaries] = kCMFormatDescriptionColorPrimaries_ITU_R_2020 }
        if v.primaries == 1 { ext[kCMFormatDescriptionExtension_ColorPrimaries] = kCMFormatDescriptionColorPrimaries_ITU_R_709_2 }
        if v.transfer == 16 { ext[kCMFormatDescriptionExtension_TransferFunction] = kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ }
        if v.transfer == 18 { ext[kCMFormatDescriptionExtension_TransferFunction] = kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG }
        if v.transfer == 1 { ext[kCMFormatDescriptionExtension_TransferFunction] = kCMFormatDescriptionTransferFunction_ITU_R_709_2 }
        if v.matrix == 9 { ext[kCMFormatDescriptionExtension_YCbCrMatrix] = kCMFormatDescriptionYCbCrMatrix_ITU_R_2020 }
        if v.matrix == 1 { ext[kCMFormatDescriptionExtension_YCbCrMatrix] = kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 }
        var fd: CMVideoFormatDescription?
        let st = CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kCMVideoCodecType_HEVC,
                                                width: Int32(v.width), height: Int32(v.height),
                                                extensions: ext as CFDictionary, formatDescriptionOut: &fd)
        guard st == noErr, let fd else { out.restore(); throw MKVError.parse("cannot create HEVC format (\(st))") }
        formatDesc = fd
    }

    // MARK: Clock

    /// Current playback position in seconds.
    var position: Double {
        stateLock.lock(); defer { stateLock.unlock() }
        if !haveBase || out.fifo.consumed == 0 { return seekTarget }
        return max(seekTarget, basePTS + out.playedSeconds - out.latencySeconds - soundDelay)
    }

    /// Called ~10x per second from the main thread to keep video locked to audio.
    func syncTick() {
        stateLock.lock()
        let started = haveBase && out.fifo.consumed > 0
        stateLock.unlock()
        guard !paused else { return }
        if !started { return }
        let pos = position
        let tbNow = CMTimeGetSeconds(CMTimebaseGetTime(timebase))
        if abs(tbNow - pos) > 0.025 {
            CMTimebaseSetTime(timebase, time: CMTime(seconds: pos, preferredTimescale: 90000))
        }
        if CMTimebaseGetRate(timebase) != 1 { CMTimebaseSetRate(timebase, rate: 1) }
        if layer.status == .failed, let e = layer.error {
            onError?("Video error: \(e.localizedDescription)")
            seek(to: pos)
        }
    }

    // MARK: Transport

    func play(from t: Double = 0) { seek(to: t) }

    func togglePause() {
        paused.toggle()
        out.paused = paused
        if paused {
            CMTimebaseSetRate(timebase, rate: 0)
        } else {
            // Resync instantly; the next tick restores rate 1.
            CMTimebaseSetTime(timebase, time: CMTime(seconds: position, preferredTimescale: 90000))
            CMTimebaseSetRate(timebase, rate: 1)
        }
    }

    func seek(by delta: Double) { seek(to: position + delta) }

    func seek(to t: Double) {
        let target = min(max(0, t), max(0, duration - 1))
        stateLock.lock()
        generation += 1
        let gen = generation
        haveBase = false
        seekTarget = target
        stateLock.unlock()

        out.fifo.flush()
        layer.flush()
        CMTimebaseSetRate(timebase, rate: 0)
        CMTimebaseSetTime(timebase, time: CMTime(seconds: target, preferredTimescale: 90000))
        let audioNum = audioTrack.number
        let sub = subtitleIndex.map { subtitleTracks[$0] }
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            readLoop(gen: gen, target: target, audioNum: audioNum, sub: sub)
        }
    }

    func cycleAudioTrack() -> MKVTrack {
        selectAudioTrack((audioIndex + 1) % audioTracks.count)
        return audioTrack
    }

    func selectAudioTrack(_ i: Int) {
        guard audioTracks.indices.contains(i), i != audioIndex else { return }
        audioIndex = i
        seek(to: position)
    }

    /// Picks a subtitle track (nil = off). Re-reads from the current position so the new track's lines load.
    func selectSubtitle(_ i: Int?) {
        let changed = i != subtitleIndex
        subtitleIndex = i.flatMap { subtitleTracks.indices.contains($0) ? $0 : nil }
        subtitles.clear()
        if changed && subtitleIndex != nil { seek(to: position) }
    }

    func setRearBoost(_ db: Double) throws {
        let pos = position
        let mode: OutputMode = db > 0 ? .pcm : .bitstream
        if mode != out.mode {
            stateLock.lock(); generation += 1; stateLock.unlock()   // stop the reader before switching
            try out.configure(mode)
            out.paused = paused
        }
        rearBoostDB = db
        rearGain = Float(pow(10, db / 20))
        seek(to: pos)
    }

    private func current() -> Int { stateLock.lock(); defer { stateLock.unlock() }; return generation }

    // MARK: Reader

    private func readLoop(gen: Int, target: Double, audioNum: UInt64, sub: MKVTrack?) {
        let targetNs = Int64(target * 1e9)
        let packer = IEC61937Packer()
        let pcm = out.mode == .pcm
        let decoder = pcm ? try? EAC3Decoder() : nil
        let outCh = out.pcmChannels
        let gain = rearGain
        let vnum = videoTrack.number
        let frameDur = videoTrack.defaultDuration > 0 ? Double(videoTrack.defaultDuration) / 1e9 : 1.0 / 24
        var gotKey = false

        var wanted: Set<UInt64> = [vnum, audioNum]
        if let sub { wanted.insert(sub.number) }
        mkv.readPackets(from: mkv.clusterOffset(for: targetNs), tracks: wanted) { pkt in
            if current() != gen { return false }
            if let sub, pkt.track == sub.number {
                let (text, italic) = SubtitleText.clean(pkt.data, codec: sub.codecID)
                let start = Double(pkt.pts) / 1e9
                let end = pkt.duration > 0 ? start + Double(pkt.duration) / 1e9 : start + 5
                subtitles.add(SubtitleCue(start: start, end: end, text: text, italic: italic))
                return true
            }
            if pkt.track == audioNum {
                if pkt.pts < targetNs { return true }
                if pcm {
                    guard let decoder else { return false }
                    for f in EAC3.split(pkt.data) where f.independent {
                        var chunk = Data()
                        decoder.decode(pkt.data.subdata(in: f.offset..<(f.offset + f.bytes))) { buf, n in
                            chunk = Player.mixForHDMI(buf, frames: n, outChannels: outCh, rearGain: gain)
                        }
                        if chunk.isEmpty { continue }
                        stateLock.lock()
                        if !haveBase && generation == gen { basePTS = Double(pkt.pts) / 1e9; haveBase = true }
                        stateLock.unlock()
                        if !out.fifo.write(chunk, generation: gen, current: current) { return false }
                    }
                    return true
                }
                for (burst, pts) in packer.feed(pkt.data, pts: pkt.pts) {
                    stateLock.lock()
                    if !haveBase && generation == gen { basePTS = Double(pts) / 1e9; haveBase = true }
                    stateLock.unlock()
                    if !out.fifo.write(burst, generation: gen, current: current) { return false }
                }
                return true
            }
            // video
            if !gotKey { if !pkt.keyframe { return true }; gotKey = true }
            guard let sb = makeSample(pkt, frameDur: frameDur, hidden: pkt.pts < targetNs - 5_000_000) else { return true }
            while !layer.isReadyForMoreMediaData {
                if current() != gen { return false }
                usleep(4000)
            }
            if current() != gen { return false }
            layer.enqueue(sb)
            return true
        }
    }

    /// Decoder order L R C LFE Ls Rs → HDMI (CEA-861) order L R LFE C RL RR [+ 2 unused], boosting the rears.
    static func mixForHDMI(_ src: UnsafeBufferPointer<Float>, frames: Int, outChannels: Int, rearGain: Float) -> Data {
        var d = Data(count: frames * outChannels * 4)
        d.withUnsafeMutableBytes { raw in
            let o = raw.bindMemory(to: Float.self)
            @inline(__always) func soft(_ x: Float) -> Float {
                let a = abs(x)
                if a <= 0.8 { return x }
                let y = 0.8 + 0.2 * tanh((a - 0.8) / 0.2)    // gentle limiter so boosted rears don't clip
                return x < 0 ? -y : y
            }
            for i in 0..<frames {
                let s = i * 6, t = i * outChannels
                o[t] = src[s]
                o[t + 1] = src[s + 1]
                o[t + 2] = src[s + 3]
                o[t + 3] = src[s + 2]
                o[t + 4] = soft(src[s + 4] * rearGain)
                o[t + 5] = soft(src[s + 5] * rearGain)
            }
        }
        return d
    }

    private func makeSample(_ pkt: MKVPacket, frameDur: Double, hidden: Bool) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        let len = pkt.data.count
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: len,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                                                 offsetToData: 0, dataLength: len, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &block) == noErr, let block else { return nil }
        pkt.data.withUnsafeBytes { raw in
            _ = CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: len)
        }
        var timing = CMSampleTimingInfo(duration: CMTime(seconds: frameDur, preferredTimescale: 90000),
                                        presentationTimeStamp: CMTime(value: pkt.pts, timescale: 1_000_000_000),
                                        decodeTimeStamp: .invalid)
        var size = len
        var sb: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: formatDesc,
                                        sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sb) == noErr,
              let sb else { return nil }
        if let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true), CFArrayGetCount(atts) > 0 {
            let d = unsafeBitCast(CFArrayGetValueAtIndex(atts, 0), to: CFMutableDictionary.self)
            if !pkt.keyframe {
                CFDictionarySetValue(d, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                     Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
            if hidden {
                CFDictionarySetValue(d, Unmanaged.passUnretained(kCMSampleAttachmentKey_DoNotDisplay).toOpaque(),
                                     Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
        }
        return sb
    }

    func shutdown() {
        stateLock.lock(); generation += 1; stateLock.unlock()
        out.restore()
    }
}
