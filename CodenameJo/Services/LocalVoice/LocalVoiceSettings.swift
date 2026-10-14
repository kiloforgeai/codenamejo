import AVFoundation
import Foundation

/// Which of the phone's own voices a local call speaks in.
enum LocalVoice: String, CaseIterable, Identifiable {
    /// Paradee-8M, Kokoro-82M's af_heart voice distilled, synthesized on the phone. See `ParadeeTTS`.
    case paradee
    /// The best English `AVSpeechSynthesizer` voice installed, and what speaks while Paradee
    /// has not downloaded yet.
    case system

    static let storageKey = "localVoice"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .paradee: return "Kokoro · Heart"
        case .system: return "System voice"
        }
    }

    static var current: LocalVoice {
        LocalVoice(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .paradee
    }
}

struct LocalVoiceCandidate: Equatable {
    let identifier: String
    let name: String
    let language: String
    /// `AVSpeechSynthesisVoiceQuality` as an ordinal: 1 default, 2 enhanced, 3 premium.
    let quality: Int

    var tier: String {
        switch quality {
        case 3: return "Premium"
        case 2: return "Enhanced"
        default: return "Compact"
        }
    }
}

enum LocalVoiceSettings {
    /// Whether the user keeps the whole call on the phone, with nothing sent to OpenAI.
    /// The fallback itself has no switch: an unreachable Live call always becomes a local one.
    static let allLocalKey = "localModeAllLocal"
    static let language = "en-US"

    static var allLocal: Bool { UserDefaults.standard.bool(forKey: allLocalKey) }

    /// The best installed English (US) voice, preferring the higher tier, then the earlier
    /// name; nil for the synthesizer's default.
    static func pick(from candidates: [LocalVoiceCandidate]) -> LocalVoiceCandidate? {
        candidates.filter { $0.language == language }
            .max { a, b in a.quality == b.quality ? a.name > b.name : a.quality < b.quality }
    }

    static func installed() -> [LocalVoiceCandidate] {
        AVSpeechSynthesisVoice.speechVoices().map {
            LocalVoiceCandidate(identifier: $0.identifier, name: $0.name, language: $0.language,
                                quality: quality($0.quality))
        }
    }

    private static func quality(_ quality: AVSpeechSynthesisVoiceQuality) -> Int {
        switch quality {
        case .premium: return 3
        case .enhanced: return 2
        default: return 1
        }
    }
}
