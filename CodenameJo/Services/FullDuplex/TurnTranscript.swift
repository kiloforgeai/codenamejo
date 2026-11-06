import Foundation

struct TurnTranscript {
    private var order: [String] = []
    private var parts: [String: String] = [:]
    mutating func finish(item: String, text: String) -> String {
        if parts[item] == nil { order.append(item) }
        parts[item] = text
        return order.compactMap { parts[$0] }.joined(separator: " ")
    }
}
