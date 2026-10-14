import Foundation

/// Times a launch somebody asked for, from process start (or the press, when warm) until
/// `DialTiming` takes over. Imports only Foundation because `JoLiveActivity` links no packages.
enum LaunchTiming {

    struct Leg {
        let label: String
        let ms: Double
    }

    /// A press later than this found a process that was already up.
    private static let coldWindow: TimeInterval = 8

    /// When this process began, from the kernel, so dyld and framework loads are included. Falls
    /// back to now, and says so, if `sysctl` fails.
    private static let processStart: CFAbsoluteTime = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        let ok = mib.withUnsafeMutableBufferPointer { buffer in
            sysctl(buffer.baseAddress, u_int(buffer.count), &info, &size, nil, 0) == 0
        }
        guard ok, info.kp_proc.p_starttime.tv_sec > 0 else {
            print("🎙️[Realtime] launch: process start unavailable — measuring from first mark")
            return CFAbsoluteTimeGetCurrent()
        }
        let epoch = Double(info.kp_proc.p_starttime.tv_sec)
            + Double(info.kp_proc.p_starttime.tv_usec) / 1_000_000
        return epoch - kCFAbsoluteTimeIntervalSince1970
    }()

    /// `nonisolated(unsafe)` behind a lock, like `DialTiming`: these marks sit on paths that must
    /// not suspend.
    private nonisolated(unsafe) static var origin: CFAbsoluteTime?
    private nonisolated(unsafe) static var lastMark: CFAbsoluteTime?
    private nonisolated(unsafe) static var legs: [Leg] = []
    private nonisolated(unsafe) static var wasCold = false
    private nonisolated(unsafe) static var _lastLaunch: [Leg] = []
    private nonisolated(unsafe) static var _lastToDialMs: Double?
    private nonisolated(unsafe) static var _lastToTalkMs: Double?
    private nonisolated(unsafe) static var _lastWasCold: Bool?
    private static let lock = NSLock()

    // MARK: - Reading (Settings → Voice → Dial timing)

    /// The pre-dial breakdown of the last launch that dialled.
    static var lastLaunch: [Leg] {
        lock.lock(); defer { lock.unlock() }
        return _lastLaunch
    }

    /// Press → the dial beginning. The stretch `DialTiming` cannot see.
    static var lastToDialMs: Double? {
        lock.lock(); defer { lock.unlock() }
        return _lastToDialMs
    }

    /// Press → the user could speak. The whole wait, and the number to judge a
    /// change to any part of this path against.
    static var lastToTalkMs: Double? {
        lock.lock(); defer { lock.unlock() }
        return _lastToTalkMs
    }

    /// Whether that launch started the process or found it running. A warm figure
    /// compared against a cold one is not a comparison.
    static var lastWasCold: Bool? {
        lock.lock(); defer { lock.unlock() }
        return _lastWasCold
    }

    // MARK: - Marking

    /// A stage of getting the app ready finished. Recorded whether or not a launch
    /// is armed — the marks are cheap and an unarmed one is simply never summarised.
    static func mark(_ label: String) {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        // Before the press: keep the mark, so a cold launch's pre-main and first
        // frame are already in hand when `armed()` adopts the timeline.
        let previous = lastMark ?? processStart
        legs.append(Leg(label: label, ms: (now - previous) * 1000))
        lastMark = now
        let total = (now - (origin ?? processStart)) * 1000
        lock.unlock()
        log("launch: \(label) \(format((now - previous) * 1000))ms (\(format(total))ms in)")
    }

    /// The user tapped the orb just after launch. Adopts the timeline only inside `coldWindow`; a
    /// warm orb tap is left to `DialTiming`.
    static func armedByOrb() {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        let sinceProcessStart = now - processStart
        guard sinceProcessStart < coldWindow, origin == nil else {
            lock.unlock()
            return
        }
        wasCold = true
        origin = processStart
        lock.unlock()
        log("launch: orb tapped \(format(sinceProcessStart * 1000))ms after process start (cold)")
    }

    /// Something asked for a session without the user touching the orb. This is the press.
    static func armed() {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        let sinceProcessStart = now - processStart
        let cold = sinceProcessStart < coldWindow
        wasCold = cold
        if cold {
            // The process came up for this press, so the launch is part of the wait
            // and the marks already taken belong to it.
            origin = processStart
        } else {
            // The app was already running. Its launch happened at some unrelated
            // moment and those legs describe nothing the user is waiting through.
            origin = now
            legs = []
            lastMark = now
        }
        lock.unlock()
        log(cold
            ? "launch: requested \(format(sinceProcessStart * 1000))ms after process start (cold)"
            : "launch: requested on a running app (warm)")
    }

    /// The dial is being placed — `DialTiming` takes it from here. Freezes the
    /// pre-dial breakdown and writes the line worth grepping on its own.
    static func dialling() {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        guard let start = origin else {
            lock.unlock()
            return
        }
        let total = (now - start) * 1000
        _lastLaunch = legs
        _lastToDialMs = total
        _lastToTalkMs = nil
        _lastWasCold = wasCold
        let breakdown = legs.map { "\($0.label) \(format($0.ms))" }.joined(separator: " · ")
        lock.unlock()
        log("launch: \(format(total))ms to dial — \(breakdown)")
    }

    /// The call is up. Called by `DialTiming.connected()` with the dial's total; clears the origin
    /// so a re-dial isn't billed as a launch.
    static func connected(dialMs: Double) {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        guard let start = origin, let toDial = _lastToDialMs else {
            lock.unlock()
            return
        }
        let total = (now - start) * 1000
        _lastToTalkMs = total
        let breakdown = _lastLaunch.map { "\($0.label) \(format($0.ms))" }.joined(separator: " · ")
        let cold = wasCold
        origin = nil
        lastMark = nil
        legs = []
        lock.unlock()
        log("launch: \(format(total))ms from press to talkable (\(cold ? "cold" : "warm"))"
            + " — launch \(format(toDial)) (\(breakdown)) + dial \(format(dialMs))")
    }

    /// The launch was armed and no dial followed: the press opened the app and it sat there.
    static func abandoned(_ reason: String) {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        guard let start = origin else {
            lock.unlock()
            return
        }
        let total = (now - start) * 1000
        let breakdown = legs.map { "\($0.label) \(format($0.ms))" }.joined(separator: " · ")
        origin = nil
        lastMark = nil
        legs = []
        lock.unlock()
        log("launch: never dialled, \(format(total))ms in — \(reason)"
            + (breakdown.isEmpty ? "" : " — \(breakdown)"))
    }

    /// `RealtimeLog` is app-target-only; the prefix is copied byte for byte so one grep finds both.
    private static func log(_ message: String) {
        print("🎙️[Realtime] \(message)")
    }

    /// Thousands separated, no decimals — same reasoning as `DialTiming.format`, and
    /// duplicated rather than shared because that one is app-target-only.
    static func format(_ ms: Double) -> String {
        let rounded = Int(ms.rounded())
        return NumberFormatter.launchMs.string(from: NSNumber(value: rounded)) ?? "\(rounded)"
    }
}

private extension NumberFormatter {
    static let launchMs: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }()
}
