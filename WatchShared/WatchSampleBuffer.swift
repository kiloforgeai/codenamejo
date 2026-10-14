import Foundation

// A bounded 16 kHz ring; the audio callback never waits for the receiving thread.
final class WatchSampleBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var samples = [Float](repeating: 0, count: 8_000)
    private var read = 0
    private var count = 0
    private var fraction = 0.0
    private var muted = false

    func append(_ pcm: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard pcm.count % 2 == 0 else { return false }
        guard !muted else { return true }
        let incoming = pcm.count / 2
        guard incoming <= samples.count - count else { return false }
        pcm.withUnsafeBytes { bytes in
            for index in 0..<incoming {
                let value = Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: index * 2, as: Int16.self))
                samples[(read + count + index) % samples.count] = Float(value)
            }
        }
        count += incoming
        return true
    }

    func setMuted(_ value: Bool) {
        lock.lock()
        muted = value
        count = 0
        fraction = 0
        lock.unlock()
    }

    func fill(_ output: UnsafeMutablePointer<Float>, count frames: Int, sampleRate: Double) {
        output.update(repeating: 0, count: frames)
        guard sampleRate > 0, lock.try() else { return }
        defer { lock.unlock() }
        guard !muted else { return }
        let step = WatchPacket.sampleRate / sampleRate
        for frame in 0..<frames {
            guard count > 1 else { fraction = 0; break }
            let first = samples[read]
            let next = samples[(read + 1) % samples.count]
            output[frame] = first + (next - first) * Float(fraction)
            fraction += step
            let consumed = min(Int(fraction), count)
            fraction -= Double(consumed)
            read = (read + consumed) % samples.count
            count -= consumed
        }
    }
}
