import Foundation

struct WatchPacket: Codable, Sendable {
    enum Kind: String, Codable { case hello, start, end, mute, ping, state, audio }
    var kind: Kind
    var callID: UUID?
    var audio: Data?
    var sequence: UInt64?
    var muted: Bool?
    var status: String?
    var message: String?

    static let sampleRate = 16_000.0
    static let packetFrames = 1_600

    var validAudio: Bool {
        kind == .audio && callID != nil && sequence != nil
            && audio?.count == Self.packetFrames * 2
    }
}

struct WatchAudioSequence {
    private var last: UInt64?

    mutating func accept(_ sequence: UInt64) -> Bool {
        guard last.map({ sequence > $0 }) ?? true else { return false }
        last = sequence
        return true
    }
}
