import Foundation

struct ModelAvailabilityCache {
    private var value: Bool?
    private var checkedAt = -Double.infinity
    var retryInterval: TimeInterval = 60

    mutating func read(now: TimeInterval, query: () -> Bool) -> Bool {
        if let value, now - checkedAt < retryInterval { return value }
        let result = query()
        value = result
        checkedAt = now
        return result
    }

    mutating func invalidate() { value = nil }
}
