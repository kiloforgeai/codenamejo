import Foundation
// WebRTC `RTC…` types come from `WebRTCAliases.swift`.

/// Live audio levels pulled from WebRTC's own stats, for the mic meter and playback
/// tracking.
struct AudioLevels: Equatable {
    /// 0…1 for the outgoing (microphone) track. Exactly 0 until the SDP exchange
    /// creates a send stream; libwebrtc fills it from the voice sender info.
    var mic: Double = 0
    /// 0…1 from our own capture tap, running from mic-live. Only for drawing the
    /// meter during the dial.
    var capture: Double = 0
    /// 0…1 for the incoming (assistant) track.
    var assistant: Double = 0

    /// The level to draw: `mic` once the send stream exists, `capture` before it so
    /// the meter moves while the user talks during the dial.
    var heard: Double { mic > 0 ? mic : capture }
}

/// Polls `RTCStatisticsReport` and extracts what we care about.
enum AudioLevelReader {

    /// 10 Hz: fast enough to follow the speech envelope, slow enough not to load the audio path.
    static let interval: Duration = .milliseconds(100)

    static func read(_ report: RTCStatisticsReport) -> AudioLevels {
        var levels = AudioLevels()

        for (_, stat) in report.statistics {
            let v = stat.values

            switch stat.type {
            case "media-source":
                guard (v["kind"] as? String) == "audio" else { continue }
                levels.mic = double(v["audioLevel"]) ?? 0

            case "inbound-rtp":
                guard (v["kind"] as? String) == "audio" else { continue }
                if let level = double(v["audioLevel"]) { levels.assistant = level }

            default:
                continue
            }
        }
        return levels
    }

    /// Stats values' concrete type varies by field and libwebrtc version.
    private static func double(_ value: NSObject?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }
}
