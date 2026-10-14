import Foundation

/// What happened the last few times iOS woke this app on its own. Entries hold no mail content:
/// a trigger, an outcome label, a duration and a timestamp. Stored in `UserDefaults`, writable on a locked phone.
enum BackgroundRefreshLog {
    /// What woke us.
    enum Trigger: String, Codable {
        /// A `content-available` push. iOS budgets these and sends none to a force-quit app.
        case silentPush = "push"
        /// The app came to the foreground. The only trigger iOS never suppresses.
        case launch = "launch"
        /// The Google consent just landed. Fires the first fill for a new user, whose
        /// `launch` pass ran on the sign-in screen with no grant to read. No throttle.
        case signIn = "signin"
        /// Someone tapped "Refresh now" in Settings. Success here doesn't prove the screen-off path works.
        case manual = "manual"
        /// A calendar-writing tool completed in a live call, where `didBecomeActive` cannot fire.
        case toolWrite = "toolwrite"
        /// A live-call calendar read was answered from a cache past `CalendarTools.cacheFreshness`;
        /// the pass freshens the next one. Calendar only.
        case staleRead = "staleread"
    }

    /// How it went. A closed set so no free text (and no mail) reaches a row.
    enum Outcome: Codable, Equatable {
        /// Mail was fetched and written. `seeded` separates a first fill from a delta, whose counts differ widely.
        case synced(cached: Int, seeded: Bool)
        /// Gmail was reachable and had nothing new.
        case upToDate
        /// The credential could not be read, carrying `GoogleCredential.Failure.logLabel`.
        case credentialFailed(String)
        /// The credential was fine and Gmail wasn't.
        case fetchFailed(String)
        /// iOS reclaimed the process before the work finished.
        case expired
    }

    /// Add new fields as optionals: `entries` decodes all-or-nothing, so a required field
    /// empties the stored history on every existing install.
    struct Entry: Codable, Identifiable {
        var id: Date { at }
        let at: Date
        let trigger: Trigger
        let outcome: Outcome
        /// Wall-clock cost of the pass.
        let ms: Int
    }

    /// How many are kept. Small, because the defaults plist is read at launch on the main thread.
    static let limit = 20

    private static let key = "backgroundRefresh.log"

    /// Newest first.
    static var entries: [Entry] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([Entry].self, from: data)
        else { return [] }
        return decoded
    }

    /// Why a pass returned without asking Gmail anything.
    enum Skip {
        /// No session, whatever the keychain still holds.
        case signedOut
        /// Inside `launchThrottle` / `pushThrottle` of the last *finished* pass.
        case throttled(secondsAgo: Int)
        /// `Gate` is held. Expected once per cold launch: `didFinishLaunching` and `didBecomeActive` both fire `.launch`.
        case alreadyRunning

        /// Kept byte-identical to the older log lines so device traces read the same.
        var logPhrase: String {
            switch self {
            case .signedOut: return "signed out"
            case .throttled(let secondsAgo): return "last pass \(secondsAgo)s ago"
            case .alreadyRunning: return "a pass is already running"
            }
        }

        var secondsAgo: Int? {
            if case .throttled(let secondsAgo) = self { return secondsAgo }
            return nil
        }
    }

    /// Record a pass that returned before doing any work. Not an `Entry`: the throttle measures
    /// against `entries.first`, so a skip in the ring would hold the floor open indefinitely.
    static func skipped(_ trigger: Trigger, _ reason: Skip) {
        RealtimeLog.log("mail: \(trigger.rawValue) skipped — \(reason.logPhrase)")
    }

    /// Append a pass, trimming to `limit`. Failures are swallowed; diagnostics must not fail a pass.
    static func record(
        _ trigger: Trigger,
        _ outcome: Outcome,
        ms: Int
    ) {
        let entry = Entry(at: Date(), trigger: trigger, outcome: outcome, ms: ms)
        var next = entries
        next.insert(entry, at: 0)
        if next.count > limit { next = Array(next.prefix(limit)) }
        guard let data = try? JSONEncoder().encode(next) else { return }
        UserDefaults.standard.set(data, forKey: key)
        // Settings draws the stored rows; `RealtimeLog` puts the same line in an attached console.
        RealtimeLog.log("mail: \(trigger.rawValue) → \(outcome.label) in \(ms)ms")
    }
}

extension BackgroundRefreshLog.Outcome {
    /// How many messages this pass wrote, when it wrote any.
    var cachedCount: Int? {
        if case .synced(let cached, _) = self { return cached }
        return nil
    }

    /// Whether it was a first fill. Absent on every other outcome.
    var wasSeed: Bool? {
        if case .synced(_, let seeded) = self { return seeded }
        return nil
    }

    /// Stable text for a log line and for a diagnostics row.
    var label: String {
        switch self {
        case .synced(let cached, let seeded):
            return "\(seeded ? "seeded" : "delta") \(cached) message(s)"
        case .upToDate: return "up to date"
        case .credentialFailed(let reason): return "credential failed: \(reason)"
        case .fetchFailed(let reason): return "fetch failed: \(reason)"
        case .expired: return "expired"
        }
    }
}
