import Foundation

/// What a hands-free dial costs, leg by leg, from the tap to the first moment the user could speak.
/// Always on: about eight log lines per dial, summarised in one `dial:` line. A leg that reads 0 was already satisfied.
enum DialTiming {

    struct Leg {
        let label: String
        let ms: Double
    }

    /// Written on the main actor, read on libwebrtc's threads. A lock rather than an actor because
    /// the marks sit on paths that must not suspend.
    private nonisolated(unsafe) static var dialStart: CFAbsoluteTime?
    private nonisolated(unsafe) static var lastMark: CFAbsoluteTime?
    private nonisolated(unsafe) static var legs: [Leg] = []
    private nonisolated(unsafe) static var _lastDial: [Leg] = []
    private nonisolated(unsafe) static var _lastTotalMs: Double?
    /// Tap → `mcp_list_tools.completed`: when the assistant can answer about mail or GitHub. Not part of connecting.
    private nonisolated(unsafe) static var _lastToolsMs: Double?
    /// Tap → mic live and capture tap running: the earliest instant the phone could hear the user.
    /// Not a leg, because the mic comes up in `prepare()`, concurrently with the mint.
    private nonisolated(unsafe) static var _lastMicLiveMs: Double?
    /// How the dial was placed. A Lock Screen press that paid for a process launch is a different distribution from a tap.
    private nonisolated(unsafe) static var _entryPoint: String = "orb"
    private nonisolated(unsafe) static var _lastEntryPoint: String = "orb"
    private static let lock = NSLock()

    // MARK: - Reading (Settings → Admin → Dial timing, debug builds)

    static var lastDial: [Leg] {
        lock.lock(); defer { lock.unlock() }
        return _lastDial
    }

    static var lastTotalMs: Double? {
        lock.lock(); defer { lock.unlock() }
        return _lastTotalMs
    }

    static var lastToolsMs: Double? {
        lock.lock(); defer { lock.unlock() }
        return _lastToolsMs
    }

    /// Tap → the phone could hear you. See `_lastMicLiveMs`.
    static var lastMicLiveMs: Double? {
        lock.lock(); defer { lock.unlock() }
        return _lastMicLiveMs
    }

    /// Milliseconds from this dial's `begin()` to now, so the agent-led opening can measure the user's whole wait.
    static var elapsedMs: Int? {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock(); defer { lock.unlock() }
        guard let start = dialStart else { return nil }
        return Int((now - start) * 1000)
    }

    /// Tap → OpenAI could hear you: `lastTotalMs` plus the deaf window that hides the connect cue from server VAD.
    static var lastHearableMs: Double? {
        lock.lock(); defer { lock.unlock() }
        guard let total = _lastTotalMs else { return nil }
        return total + _deafWindowMs
    }

    /// How long the mic was held silent after the call came up. Zero when the cue already played at mic-live.
    private nonisolated(unsafe) static var _deafWindowMs = ConnectCue.micDeafWindowMs

    /// The connect cue is not going to run, so no deaf window follows.
    static func noDeafWindow() {
        lock.lock()
        _deafWindowMs = 0
        lock.unlock()
    }

    /// How the last dial was placed, for the Settings readout and the analytics event.
    static var lastEntryPoint: String {
        lock.lock(); defer { lock.unlock() }
        return _lastEntryPoint
    }

    // MARK: - Marking

    /// What is about to place a dial — `orb`, `control`, `action-button`, `siri`, `shortcut`, `onboarding`, `carplay`,
    /// `resume`. Set at the press because `begin()` runs deep inside `start()`; sticky until the next dial.
    static func willDial(from entryPoint: String) {
        lock.lock()
        _entryPoint = entryPoint
        lock.unlock()
    }

    /// The tap. Everything after this is the wait the user is sitting through.
    static func begin() {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        dialStart = now
        lastMark = now
        legs = []
        // Cleared so a dial that never connected doesn't leave its figure on the next one.
        _lastToolsMs = nil
        _lastMicLiveMs = nil
        // Reset per dial: a skipped deaf window on the last dial must not shorten this one.
        _deafWindowMs = ConnectCue.micDeafWindowMs
        let entryPoint = _entryPoint
        lock.unlock()
        RealtimeLog.log("dial: started (\(entryPoint))")
    }

    /// The mic is live and the capture tap is running. Recorded once per dial.
    static func micLive() {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        guard let start = dialStart, _lastMicLiveMs == nil else {
            lock.unlock()
            return
        }
        let ms = (now - start) * 1000
        _lastMicLiveMs = ms
        lock.unlock()
        RealtimeLog.log("dial: \(format(ms))ms to mic live")
    }

    /// One leg finished. The delta since the previous mark is this leg's cost.
    static func mark(_ label: String) {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        guard let start = dialStart, let previous = lastMark else {
            lock.unlock()
            return
        }
        let ms = (now - previous) * 1000
        let total = (now - start) * 1000
        legs.append(Leg(label: label, ms: ms))
        lastMark = now
        lock.unlock()
        RealtimeLog.log("dial: \(label) \(format(ms))ms (\(format(total))ms in)")
    }

    /// ICE settled or the data channel opened — the user can talk. Freezes the
    /// breakdown and writes the one line worth grepping.
    static func connected() {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        guard let start = dialStart else {
            lock.unlock()
            return
        }
        let total = (now - start) * 1000
        if let previous = lastMark, (now - previous) * 1000 > 1 {
            legs.append(Leg(label: "ICE + data channel", ms: (now - previous) * 1000))
        }
        _lastDial = legs
        _lastTotalMs = total
        _lastEntryPoint = _entryPoint
        let breakdown = legs.map { "\($0.label) \(format($0.ms))" }.joined(separator: " · ")
        let micLive = _lastMicLiveMs
        let entryPoint = _entryPoint
        let frozen = legs
        // `dialStart` stays for `toolsListed()`; there are no more legs to measure against `lastMark`.
        lastMark = nil
        lock.unlock()
        // `first listen` is when the session is up; `hearable` is when the mic comes off zero gain after the connect cue.
        let hearable = total + _deafWindowMs
        RealtimeLog.log("dial: \(format(total))ms to first listen"
            + " (\(format(hearable))ms to hearable) — \(breakdown)"
            + (micLive.map { " · mic live at \(format($0))" } ?? ""))
        // A no-op for an orb tap; for a Lock Screen or Action Button dial it writes the press-to-talkable figure.
        LaunchTiming.connected(dialMs: total)
        // Persisted because this path's variance is large enough that only a distribution means anything.
        let wasCold = LaunchTiming.lastWasCold
        persist(totalMs: total, hearableMs: hearable, micLiveMs: micLive,
                legs: frozen, entryPoint: entryPoint, wasCold: wasCold)
    }

    /// `mcp_list_tools.completed` — server-side tools are reachable.
    static func toolsListed() {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        guard let start = dialStart, _lastToolsMs == nil else {
            lock.unlock()
            return
        }
        let ms = (now - start) * 1000
        _lastToolsMs = ms
        let entryPoint = _entryPoint
        lock.unlock()
        RealtimeLog.log("dial: \(format(ms))ms to tools reachable")
    }

    /// The dial failed or ended before it connected. Logged because a dial the user gave up on writes no summary line.
    static func abandoned(_ reason: String) {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        guard let start = dialStart else {
            lock.unlock()
            return
        }
        let total = (now - start) * 1000
        let breakdown = legs.map { "\($0.label) \(format($0.ms))" }.joined(separator: " · ")
        dialStart = nil
        lastMark = nil
        lock.unlock()
        RealtimeLog.log("dial: abandoned after \(format(total))ms — \(reason)"
            + (breakdown.isEmpty ? "" : " — \(breakdown)"))
        // A launch whose dial died must be released, or it is attributed to the next dial.
        LaunchTiming.abandoned("dial abandoned — \(reason)")
    }

    // MARK: - Surviving a relaunch

    /// One finished dial, small enough that twenty of them are a few kilobytes.
    struct Record: Codable, Identifiable {
        let at: Date
        let totalMs: Double
        let hearableMs: Double
        let micLiveMs: Double?
        let entryPoint: String
        /// Whether this dial's process came up for it. Nil when `LaunchTiming` wasn't armed, rather than a guess.
        let wasCold: Bool?
        /// Label → ms, as parallel arrays to keep the order.
        let legLabels: [String]
        let legMs: [Double]

        var id: Date { at }
        var legs: [Leg] { zip(legLabels, legMs).map { Leg(label: $0, ms: $1) } }
    }

    private static let historyKey = "dialTiming.recent"
    private static let historyLimit = 20

    /// The last twenty dials, newest first. Persisted so a cold launch's dial survives the relaunch needed to read it.
    static var recent: [Record] {
        guard let data = UserDefaults.standard.data(forKey: historyKey),
              let decoded = try? JSONDecoder().decode([Record].self, from: data)
        else { return [] }
        return decoded
    }

    /// Append and trim. Called on libwebrtc's thread; `UserDefaults` is thread-safe.
    private static func persist(
        totalMs: Double,
        hearableMs: Double,
        micLiveMs: Double?,
        legs: [Leg],
        entryPoint: String,
        wasCold: Bool?
    ) {
        let record = Record(
            at: Date(),
            totalMs: totalMs,
            hearableMs: hearableMs,
            micLiveMs: micLiveMs,
            entryPoint: entryPoint,
            wasCold: wasCold,
            legLabels: legs.map(\.label),
            legMs: legs.map(\.ms))
        let trimmed = ([record] + recent).prefix(historyLimit)
        guard let data = try? JSONEncoder().encode(Array(trimmed)) else { return }
        UserDefaults.standard.set(data, forKey: historyKey)
    }

    /// The median of a set of dials. Not a mean: one slow SDP outlier moves a mean by hundreds of milliseconds.
    static func medianTotalMs(entryPoint: String? = nil, coldOnly: Bool = false) -> Double? {
        let pool = recent
            .filter { entryPoint == nil || $0.entryPoint == entryPoint }
            .filter { !coldOnly || $0.wasCold == true }
            .map(\.totalMs)
            .sorted()
        guard !pool.isEmpty else { return nil }
        return pool[pool.count / 2]
    }

    /// Thousands separated, no decimals.
    static func format(_ ms: Double) -> String {
        let rounded = Int(ms.rounded())
        return NumberFormatter.dialMs.string(from: NSNumber(value: rounded)) ?? "\(rounded)"
    }
}

private extension NumberFormatter {
    static let dialMs: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }()
}
