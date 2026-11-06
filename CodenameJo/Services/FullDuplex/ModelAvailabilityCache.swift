import Foundation

struct ModelAvailabilityCache {
    private var value: Bool?
    private var checkedAt = -Double.infinity
    var retryInterval: TimeInterval = 60

    mutating func read(now: TimeInterval, onChange: ((Bool) -> Void)? = nil, query: () -> Bool) -> Bool {
        if let value, now - checkedAt < retryInterval { return value }
        let result = query()
        let changed = value != result
        value = result
        checkedAt = now
        if changed { onChange?(result) }
        return result
    }

    @discardableResult
    mutating func suppress(now: TimeInterval) -> Bool {
        let changed = value != false
        value = false
        checkedAt = now
        return changed
    }

    mutating func invalidate() { value = nil }
}
