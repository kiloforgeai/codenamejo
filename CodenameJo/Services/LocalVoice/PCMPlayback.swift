import AVFoundation

/// One playback session for synthesized speech: 24 kHz mono buffers queued on a player node.
/// `append` and `stop(_:)` act only on their own token, so a late teardown cannot stop the next reply.
actor PCMPlayback {
    struct Failure: LocalizedError {
        var errorDescription: String? { "Unable to allocate speech audio." }
    }

    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var pending = 0
    /// Audio queued and not yet heard, so `drain` can stop waiting on an engine that has gone quiet.
    private var queuedSeconds: Double = 0
    private var epoch = UUID()
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private static let format = AVAudioFormat(standardFormatWithSampleRate: ParadeeTTS.sampleRate, channels: 1)!

    func start() throws -> UUID {
        stop()
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: Self.format)
        try engine.start()
        player.play()
        self.engine = engine
        self.player = player
        return epoch
    }

    func append(_ samples: [Float], session: UUID) throws {
        guard session == epoch, let player else { throw CancellationError() }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw Failure()
        }
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress { buffer.floatChannelData![0].update(from: base, count: source.count) }
        }
        pending += 1
        let seconds = Double(samples.count) / Self.format.sampleRate
        queuedSeconds += seconds
        let current = epoch
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
            Task { await self.completed(epoch: current, seconds: seconds) }
        }
    }

    /// Waits until everything queued has been heard — or, if the engine stopped calling back
    /// (a route change, an interruption), until it should have been, plus a margin.
    func drain() async {
        if pending == 0 { return }
        let current = epoch
        let limit = queuedSeconds + 2
        Task {
            try? await Task.sleep(for: .seconds(limit))
            await self.drainTimedOut(epoch: current)
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Stops this session; a stale token does nothing.
    func stop(_ session: UUID) {
        guard session == epoch else { return }
        stop()
    }

    /// Stops whatever is playing.
    func stop() {
        epoch = UUID()
        player?.stop()
        engine?.stop()
        player = nil
        engine = nil
        pending = 0
        queuedSeconds = 0
        resumeWaiters()
    }

    private func completed(epoch: UUID, seconds: Double) {
        guard epoch == self.epoch else { return }
        pending -= 1
        queuedSeconds = max(0, queuedSeconds - seconds)
        if pending == 0 { resumeWaiters() }
    }

    private func drainTimedOut(epoch: UUID) {
        guard epoch == self.epoch, !waiters.isEmpty else { return }
        RealtimeLog.log("local-voice: playback stopped calling back — ending the reply")
        resumeWaiters()
    }

    private func resumeWaiters() {
        let old = waiters
        waiters.removeAll()
        old.forEach { $0.resume() }
    }
}
