import Foundation

/// When a local call's turn is over, on the audio clock. Smart Turn is asked after 0.25 s of silence, then every 0.2 s;
/// the score needed falls from 0.85 to 0.5 by 0.75 s, and 1.5 s ends the turn regardless.
struct SmartTurnPolicy {
    private(set) var heardSpeech = false
    private(set) var silence: Double = 0
    private(set) var ready = false
    private var nextCheck = SmartTurnPolicy.firstCheck
    static let firstCheck = 0.25
    static let recheck = 0.2
    static let maximumSilence = 1.5
    /// Silero's speech probability at or above which a chunk is speech.
    static let speech: Float = 0.35

    mutating func observe(probability: Float, duration: Double) {
        if probability >= Self.speech {
            heardSpeech = true
            silence = 0
            nextCheck = Self.firstCheck
            ready = false
        } else if heardSpeech {
            silence += duration
            if silence >= Self.maximumSilence { ready = true }
        }
    }

    var shouldClassify: Bool { heardSpeech && silence >= nextCheck && !ready }

    /// Score needed to end the turn at the current silence.
    var threshold: Float {
        Float(max(0.5, 0.85 - (silence - Self.firstCheck) * 0.7))
    }

    mutating func classify(completion: Float) {
        nextCheck = silence + Self.recheck
        ready = completion >= threshold
    }
}
