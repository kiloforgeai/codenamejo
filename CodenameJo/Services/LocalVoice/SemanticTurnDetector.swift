import CoreML
import FluidAudio
import Foundation

/// Decides from the audio that a thought is finished: Silero VAD finds the silence, and Smart Turn v3.2
/// (pipecat-ai, BSD-2-Clause, under `SmartTurn/`) judges the last eight seconds. Unprepared, the call uses `LocalTurnPolicy`.
actor SemanticTurnDetector {
    struct Failure: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    /// 16 kHz mono, the rate both models take.
    static let sampleRate: Double = 16_000
    private static let window = 128_000

    private var model: MLModel?
    private var vad: VadManager?
    private var state: VadStreamState?
    private var pending: [Float] = []
    private var recent: [Float] = []
    private var policy = SmartTurnPolicy()
    /// Bumped by `reset`, so a `consume` suspended across one cannot write its stale VAD state back.
    private var generation = 0

    var isReady: Bool { model != nil && vad != nil }

    func prepare() async throws {
        if model == nil {
            guard let url = Bundle.main.url(forResource: "smart_turn", withExtension: "mlmodelc",
                                            subdirectory: "SmartTurn") else {
                throw Failure(reason: "The turn detector is missing from this build.")
            }
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .cpuAndNeuralEngine
            model = try MLModel(contentsOf: url, configuration: configuration)
        }
        if vad == nil { vad = try await VadManager(config: VadConfig(defaultThreshold: 0.5)) }
        RealtimeLog.log("local-voice: Smart Turn v3.2 and Silero ready")
    }

    func reset() async {
        generation &+= 1
        pending.removeAll(keepingCapacity: true)
        recent.removeAll(keepingCapacity: true)
        policy = SmartTurnPolicy()
        state = await vad?.makeStreamState()
    }

    /// Feeds 16 kHz samples; true once the turn is over.
    func consume(_ samples: [Float]) async throws -> Bool {
        guard let vad, let model else { throw Failure(reason: "Turn detection isn't ready.") }
        pending += samples
        while pending.count >= VadManager.chunkSize {
            try Task.checkCancellation()
            let chunk = Array(pending.prefix(VadManager.chunkSize))
            pending.removeFirst(VadManager.chunkSize)
            recent += chunk
            if recent.count > Self.window { recent.removeFirst(recent.count - Self.window) }
            let current: VadStreamState
            if let state { current = state } else { current = await vad.makeStreamState() }
            let started = generation
            let result = try await vad.processStreamingChunk(chunk, state: current)
            try Task.checkCancellation()
            guard started == generation else { return false }
            state = result.state
            policy.observe(probability: result.probability, duration: Double(chunk.count) / Self.sampleRate)
            guard policy.shouldClassify else { continue }
            let audio = try MLMultiArray(shape: [1, NSNumber(value: Self.window)], dataType: .float32)
            let pointer = audio.dataPointer.assumingMemoryBound(to: Float.self)
            pointer.initialize(repeating: 0, count: Self.window)
            recent.withUnsafeBufferPointer { source in
                if let base = source.baseAddress {
                    pointer.advanced(by: Self.window - source.count).update(from: base, count: source.count)
                }
            }
            let inferenceStarted = Date()
            let input = try MLDictionaryFeatureProvider(dictionary: ["audio": MLFeatureValue(multiArray: audio)])
            let prediction = try await model.prediction(from: input)
            try Task.checkCancellation()
            guard started == generation else { return false }
            guard let value = prediction.featureValue(for: "probability")?.multiArrayValue?[0].floatValue,
                  value.isFinite else { throw Failure(reason: "The turn detector returned an invalid score.") }
            let threshold = policy.threshold
            policy.classify(completion: value)
            RealtimeLog.log(String(format: "local-voice: turn p=%.2f need=%.2f ready=%@ silence=%.2fs in %.0f ms",
                                   value, threshold, policy.ready ? "yes" : "no", policy.silence,
                                   Date().timeIntervalSince(inferenceStarted) * 1000))
        }
        return policy.ready
    }
}
