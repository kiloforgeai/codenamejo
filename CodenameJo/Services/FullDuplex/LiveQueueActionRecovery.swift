import Foundation

/// Tracks unresolved requests separately from speech and shortcut recognition.
struct LiveQueueActionRecovery {
    struct Anchor {
        let step: String
        let profileId: String
        let revision: Int

        func matches(step: String?, profileId: String?, revision: Int) -> Bool {
            self.step == step && self.profileId == profileId && self.revision == revision
        }
    }

    enum Decision { case retry, failed }
    private var deadline: TimeInterval
    private var retried = false
    private(set) var finished = false

    init(now: TimeInterval) {
        deadline = now + 1.5
    }

    mutating func started() { finished = true }

    mutating func poll(now: TimeInterval) -> Decision? {
        guard !finished, now >= deadline else { return nil }
        if retried {
            finished = true
            return .failed
        }
        retried = true
        deadline = now + 5
        return .retry
    }
}
