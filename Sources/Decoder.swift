import Foundation
import AudioToolbox

// Decodes E-AC-3 sync frames to interleaved Float32 5.1 (L R C LFE Ls Rs) with AudioToolbox.

final class EAC3Decoder {
    private var converter: AudioConverterRef?
    private let packetBuf = UnsafeMutableRawPointer.allocate(byteCount: 16384, alignment: 16)
    private var packetBytes = 0
    private let packetDesc = UnsafeMutablePointer<AudioStreamPacketDescription>.allocate(capacity: 1)
    private var supplied = false
    private var outBuf = [Float](repeating: 0, count: 1536 * 6)
    static let channels = 6

    init() throws {
        var inFmt = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatEnhancedAC3, mFormatFlags: 0,
                                                mBytesPerPacket: 0, mFramesPerPacket: 1536, mBytesPerFrame: 0,
                                                mChannelsPerFrame: 6, mBitsPerChannel: 0, mReserved: 0)
        var outFmt = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
                                                 mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                                 mBytesPerPacket: 24, mFramesPerPacket: 1, mBytesPerFrame: 24,
                                                 mChannelsPerFrame: 6, mBitsPerChannel: 32, mReserved: 0)
        let st = AudioConverterNew(&inFmt, &outFmt, &converter)
        guard st == noErr, let converter else { throw AudioOutError.failed("creating Dolby decoder", st) }
        // Fix the output channel order to L R C LFE Ls Rs.
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_MPEG_5_1_A
        AudioConverterSetProperty(converter, kAudioConverterOutputChannelLayout,
                                  UInt32(MemoryLayout<AudioChannelLayout>.size), &layout)
    }

    deinit {
        if let c = converter { AudioConverterDispose(c) }
        packetBuf.deallocate()
        packetDesc.deallocate()
    }

    func reset() { if let c = converter { AudioConverterReset(c) } }

    /// Decodes one E-AC-3 sync frame (plus any dependent frames). Returns frames decoded (normally 1536).
    func decode(_ frame: Data, _ body: (UnsafeBufferPointer<Float>, Int) -> Void) {
        guard let converter else { return }
        packetBytes = min(frame.count, 16384)
        frame.withUnsafeBytes { packetBuf.copyMemory(from: $0.baseAddress!, byteCount: packetBytes) }
        packetDesc.pointee = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(packetBytes))
        supplied = false
        var frames: UInt32 = 1536
        outBuf.withUnsafeMutableBytes { out in
            var abl = AudioBufferList(mNumberBuffers: 1,
                                      mBuffers: AudioBuffer(mNumberChannels: 6, mDataByteSize: UInt32(out.count), mData: out.baseAddress))
            let me = Unmanaged.passUnretained(self).toOpaque()
            let st = AudioConverterFillComplexBuffer(converter, { _, ioPackets, ioData, outDesc, user in
                let d = Unmanaged<EAC3Decoder>.fromOpaque(user!).takeUnretainedValue()
                if d.supplied { ioPackets.pointee = 0; return 1 }   // no more input for this call
                d.supplied = true
                ioPackets.pointee = 1
                ioData.pointee.mNumberBuffers = 1
                ioData.pointee.mBuffers.mData = d.packetBuf
                ioData.pointee.mBuffers.mDataByteSize = UInt32(d.packetBytes)
                ioData.pointee.mBuffers.mNumberChannels = 6
                if let outDesc { outDesc.pointee = d.packetDesc }
                return noErr
            }, me, &frames, &abl, nil)
            if st != noErr && st != 1 && frames == 0 { return }
        }
        guard frames > 0 else { return }
        outBuf.withUnsafeBufferPointer { body($0, Int(frames)) }
    }
}
