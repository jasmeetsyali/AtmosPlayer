import Foundation
import CoreAudio

// Bit-exact HDMI output: hogs the HDMI device, switches its stream to the
// E-AC-3 (IEC 61937, 192 kHz) physical format and feeds bursts straight through.

enum AudioOutError: Error, CustomStringConvertible {
    case noDevice, noStream, noFormat([String]), failed(String, OSStatus)
    var description: String {
        switch self {
        case .noDevice: return "no HDMI audio device found"
        case .noStream: return "HDMI device has no output stream"
        case .noFormat(let f): return "device offers no E-AC-3 passthrough format. Formats: \(f.joined(separator: ", "))"
        case .failed(let what, let st): return "\(what) failed (\(st))"
        }
    }
}

func fourcc(_ v: UInt32) -> String {
    let b = [24, 16, 8, 0].map { UInt8((v >> $0) & 0xFF) }
    return String(bytes: b.map { (32...126).contains($0) ? $0 : 63 }, encoding: .ascii) ?? "?"
}

private func addr(_ sel: AudioObjectPropertySelector,
                  _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

private func getArray<T>(_ obj: AudioObjectID, _ a: AudioObjectPropertyAddress, _ type: T.Type) -> [T] {
    var a = a
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(obj, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
    let n = Int(size) / MemoryLayout<T>.stride
    let buf = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
    defer { buf.deallocate() }
    guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, buf) == noErr else { return [] }
    let typed = buf.bindMemory(to: T.self, capacity: n)
    return Array(UnsafeBufferPointer(start: typed, count: n))
}

private func getValue<T>(_ obj: AudioObjectID, _ a: AudioObjectPropertyAddress, _ initial: T) -> T? {
    var a = a
    var v = initial
    var size = UInt32(MemoryLayout<T>.size)
    return AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &v) == noErr ? v : nil
}

@discardableResult
private func setValue<T>(_ obj: AudioObjectID, _ a: AudioObjectPropertyAddress, _ value: T) -> OSStatus {
    var a = a
    var v = value
    return AudioObjectSetPropertyData(obj, &a, 0, nil, UInt32(MemoryLayout<T>.size), &v)
}

private func deviceName(_ dev: AudioObjectID) -> String {
    var a = addr(kAudioObjectPropertyName)
    var name: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &name) == noErr, let n = name else { return "" }
    return n.takeRetainedValue() as String
}

/// Thread-safe byte FIFO with a blocking writer.
final class ByteFIFO {
    private var buf = Data()
    private var readPos = 0
    private let cond = NSCondition()
    let capacity: Int
    private(set) var consumed: Int64 = 0      // total bytes handed to the device
    var closed = false

    init(capacity: Int) { self.capacity = capacity }

    var count: Int { cond.lock(); defer { cond.unlock() }; return buf.count - readPos }

    /// Blocks while full. Returns false if the FIFO was flushed/closed while waiting.
    func write(_ d: Data, generation: Int, current: () -> Int) -> Bool {
        cond.lock()
        defer { cond.unlock() }
        while buf.count - readPos >= capacity && !closed && generation == current() { cond.wait() }
        if closed || generation != current() { return false }
        if readPos > 0 && readPos > buf.count / 2 { buf.removeSubrange(0..<readPos); readPos = 0 }
        buf.append(d)
        return true
    }

    /// Called from the realtime IO thread. Fills `dst` and pads with zeros.
    func read(into dst: UnsafeMutableRawPointer, _ n: Int, paused: Bool) {
        cond.lock()
        var got = 0
        if !paused {
            got = min(n, buf.count - readPos)
            if got > 0 {
                buf.withUnsafeBytes { src in
                    dst.copyMemory(from: src.baseAddress! + readPos, byteCount: got)
                }
                readPos += got
                consumed += Int64(got)
            }
        }
        cond.signal()
        cond.unlock()
        if got < n { memset(dst + got, 0, n - got) }
    }

    func flush() {
        cond.lock()
        buf.removeAll(keepingCapacity: true)
        readPos = 0
        consumed = 0
        cond.broadcast()
        cond.unlock()
    }

    func wake() { cond.lock(); cond.broadcast(); cond.unlock() }
}

/// Passthrough format to use; override with ATMOS_FMT=cc+3 etc.
let preferredFormatID: UInt32 = {
    let s = ProcessInfo.processInfo.environment["ATMOS_FMT"] ?? "cec3"
    return s.utf8.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
}()

enum OutputMode: Equatable {
    case bitstream      // E-AC-3 / Atmos passed through untouched
    case pcm            // decoded 5.1 PCM (used by Rear Boost)
}

final class HDMIBitstreamOutput {
    let device: AudioObjectID
    let deviceLabel: String
    private let stream: AudioStreamID
    private var originalFormat = AudioStreamBasicDescription()
    private var savedOriginal = false
    private var hadMixing: UInt32? = nil
    private var hogging = false
    private var ioProc: AudioDeviceIOProcID?
    let fifo = ByteFIFO(capacity: IEC61937Packer.burstBytes * 64)   // ~2 s of bitstream, ~1.4 s of PCM
    var paused = false
    private(set) var latencySeconds: Double = 0
    private(set) var mode: OutputMode = .bitstream
    /// Bytes of output per second of audio in the current mode.
    private(set) var bytesPerSecond: Double = Double(IEC61937Packer.burstBytes) / 0.032
    /// PCM mode: interleaved Float32 channels on the device.
    private(set) var pcmChannels = 6
    private var running = false

    init() throws {
        let devices = getArray(AudioObjectID(kAudioObjectSystemObject), addr(kAudioHardwarePropertyDevices), AudioObjectID.self)
        var chosen: AudioObjectID? = nil
        for d in devices {
            let streams = getArray(d, addr(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput), AudioStreamID.self)
            guard !streams.isEmpty else { continue }
            let transport = getValue(d, addr(kAudioDevicePropertyTransportType), UInt32(0)) ?? 0
            if transport == kAudioDeviceTransportTypeHDMI || transport == kAudioDeviceTransportTypeDisplayPort {
                // prefer a device that actually offers E-AC-3
                let fmts = getArray(streams[0], addr(kAudioStreamPropertyAvailablePhysicalFormats), AudioStreamRangedDescription.self)
                if fmts.contains(where: { HDMIBitstreamOutput.isEAC3($0.mFormat) }) { chosen = d; break }
                if chosen == nil && deviceName(d).contains("HDMI") { chosen = d }
            }
        }
        guard let dev = chosen else { throw AudioOutError.noDevice }
        device = dev
        deviceLabel = deviceName(dev)
        let streams = getArray(dev, addr(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput), AudioStreamID.self)
        guard let st = streams.first else { throw AudioOutError.noStream }
        stream = st
    }

    static func isEAC3(_ f: AudioStreamBasicDescription) -> Bool {
        // 'cec3' is the IEC 60958 / 61937 E-AC-3 format CoreAudio exposes on HDMI.
        f.mFormatID == preferredFormatID && f.mSampleRate >= 191_999 && f.mSampleRate <= 192_001
    }

    func availableFormats() -> [String] {
        getArray(stream, addr(kAudioStreamPropertyAvailablePhysicalFormats), AudioStreamRangedDescription.self).map {
            "\(fourcc($0.mFormat.mFormatID))@\(Int($0.mFormat.mSampleRate))/\($0.mFormat.mChannelsPerFrame)ch"
        }
    }

    func start() throws { try configure(.bitstream) }

    /// Switches the HDMI stream between Dolby passthrough and 48 kHz multichannel PCM.
    func configure(_ newMode: OutputMode) throws {
        stopIO()
        fifo.flush()
        fifo.closed = false
        let fmts = getArray(stream, addr(kAudioStreamPropertyAvailablePhysicalFormats), AudioStreamRangedDescription.self).map(\.mFormat)
        let target: AudioStreamBasicDescription
        switch newMode {
        case .bitstream:
            guard let t = fmts.first(where: HDMIBitstreamOutput.isEAC3) else { throw AudioOutError.noFormat(availableFormats()) }
            target = t
        case .pcm:
            let pcm = fmts.filter { $0.mFormatID == kAudioFormatLinearPCM && Int($0.mSampleRate) == 48000 }
            guard let t = (pcm.filter { $0.mChannelsPerFrame == 6 } + pcm.filter { $0.mChannelsPerFrame == 8 })
                    .max(by: { $0.mBitsPerChannel < $1.mBitsPerChannel }) else {
                throw AudioOutError.noFormat(availableFormats())
            }
            target = t
        }
        if !savedOriginal {
            originalFormat = getValue(stream, addr(kAudioStreamPropertyPhysicalFormat), AudioStreamBasicDescription()) ?? originalFormat
            savedOriginal = true
        }

        // Exclusive access
        var st: OSStatus
        if !hogging {
            st = setValue(device, addr(kAudioDevicePropertyHogMode), pid_t(getpid()))
            if st != noErr { throw AudioOutError.failed("taking exclusive access", st) }
            hogging = true
            if let mix = getValue(device, addr(kAudioDevicePropertySupportsMixing), UInt32(1)) {
                hadMixing = mix
                setValue(device, addr(kAudioDevicePropertySupportsMixing), UInt32(0))
            }
        }
        st = setValue(stream, addr(kAudioStreamPropertyPhysicalFormat), target)
        if st != noErr { restore(); throw AudioOutError.failed("switching output format", st) }
        // wait for the change to take effect
        for _ in 0..<40 {
            if let cur = getValue(stream, addr(kAudioStreamPropertyPhysicalFormat), AudioStreamBasicDescription()),
               cur.mFormatID == target.mFormatID, cur.mChannelsPerFrame == target.mChannelsPerFrame,
               cur.mSampleRate == target.mSampleRate { break }
            usleep(50_000)
        }

        if newMode == .pcm {
            // Ask for interleaved Float32 in the callback.
            let ch = target.mChannelsPerFrame
            let virt = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
                                                   mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                                   mBytesPerPacket: 4 * ch, mFramesPerPacket: 1, mBytesPerFrame: 4 * ch,
                                                   mChannelsPerFrame: ch, mBitsPerChannel: 32, mReserved: 0)
            setValue(stream, addr(kAudioStreamPropertyVirtualFormat), virt)
            let cur = getValue(stream, addr(kAudioStreamPropertyVirtualFormat), AudioStreamBasicDescription()) ?? virt
            guard cur.mFormatFlags & kAudioFormatFlagIsFloat != 0, cur.mBitsPerChannel == 32 else {
                restore(); throw AudioOutError.failed("setting float PCM output", -1)
            }
            pcmChannels = Int(cur.mChannelsPerFrame)
            bytesPerSecond = 48000 * 4 * Double(pcmChannels)
        } else {
            bytesPerSecond = Double(IEC61937Packer.burstBytes) / 0.032
        }

        let devLat = getValue(device, addr(kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput), UInt32(0)) ?? 0
        let safety = getValue(device, addr(kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput), UInt32(0)) ?? 0
        let stLat = getValue(stream, addr(kAudioStreamPropertyLatency), UInt32(0)) ?? 0
        let bufFrames = getValue(device, addr(kAudioDevicePropertyBufferFrameSize), UInt32(0)) ?? 0
        latencySeconds = Double(devLat + safety + stLat + bufFrames) / target.mSampleRate
        mode = newMode

        let fifo = self.fifo
        st = AudioDeviceCreateIOProcIDWithBlock(&ioProc, device, nil) { [unowned self] _, _, _, outData, _ in
            let abl = UnsafeMutableAudioBufferListPointer(outData)
            for b in abl {
                guard let p = b.mData else { continue }
                fifo.read(into: p, Int(b.mDataByteSize), paused: self.paused)
            }
        }
        if st != noErr { restore(); throw AudioOutError.failed("creating audio callback", st) }
        st = AudioDeviceStart(device, ioProc)
        if st != noErr { restore(); throw AudioOutError.failed("starting audio", st) }
        running = true
    }

    /// Seconds of audio content consumed by the device so far (excluding output latency).
    var playedSeconds: Double { Double(fifo.consumed) / bytesPerSecond }

    private func stopIO() {
        if running, let p = ioProc { AudioDeviceStop(device, p) }
        if let p = ioProc { AudioDeviceDestroyIOProcID(device, p); ioProc = nil }
        running = false
    }

    func restore() {
        stopIO()
        if savedOriginal && originalFormat.mFormatID != 0 {
            setValue(stream, addr(kAudioStreamPropertyPhysicalFormat), originalFormat)
        }
        if let m = hadMixing { setValue(device, addr(kAudioDevicePropertySupportsMixing), m); hadMixing = nil }
        if hogging { setValue(device, addr(kAudioDevicePropertyHogMode), pid_t(-1)); hogging = false }
        fifo.closed = true
        fifo.wake()
    }

    deinit { restore() }
}
