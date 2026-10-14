import AVFoundation

// Queue-confined: one converter preserves resampling state across successive audio buffers.
final class WatchPCMEncoder {
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private var pending = Data()
    private var sequence: UInt64 = 0
    private let output = AVAudioFormat(commonFormat: .pcmFormatInt16,
        sampleRate: WatchPacket.sampleRate, channels: 1, interleaved: false)!

    func encode(_ buffer: AVAudioPCMBuffer, callID: UUID,
                send: (WatchPacket) -> Void) throws {
        if sourceFormat != buffer.format {
            sourceFormat = buffer.format
            converter = AVAudioConverter(from: buffer.format, to: output)
        }
        guard let converter else { throw WatchAudioError.conversion }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * output.sampleRate / buffer.format.sampleRate) + 64
        guard let converted = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else {
            throw WatchAudioError.conversion
        }
        var supplied = false
        var error: NSError?
        let result = converter.convert(to: converted, error: &error) { _, status in
            guard !supplied else { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        if let error { throw error }
        guard result != .error, let samples = converted.int16ChannelData?[0] else {
            throw WatchAudioError.conversion
        }
        pending.append(Data(bytes: samples, count: Int(converted.frameLength) * 2))
        let size = WatchPacket.packetFrames * 2
        while pending.count >= size {
            send(WatchPacket(kind: .audio, callID: callID,
                             audio: Data(pending.prefix(size)), sequence: sequence))
            sequence += 1
            pending.removeFirst(size)
        }
    }

    static func copy(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength) else { return nil }
        copy.frameLength = source.frameLength
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let targetBuffers = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (source, target) in zip(sourceBuffers, targetBuffers) {
            guard let from = source.mData, let to = target.mData else { return nil }
            memcpy(to, from, Int(source.mDataByteSize))
        }
        return copy
    }
}

enum WatchAudioError: LocalizedError {
    case conversion, microphone, backlog
    var errorDescription: String? {
        switch self {
        case .conversion: return "Could not convert Watch audio. Please end the call and try again."
        case .microphone: return "Allow microphone access in Settings to talk to Jo."
        case .backlog: return "Watch audio processing fell behind. Please start a new call."
        }
    }
}
