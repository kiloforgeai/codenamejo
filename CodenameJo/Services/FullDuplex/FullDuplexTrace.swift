import Foundation

/// A timestamped trace of every `oai-events` frame, both directions, for ordering questions the typed log drops.
/// Off by default; enable with the `-fullDuplexTrace YES` launch argument. Times are ms since the dial.
enum FullDuplexTrace {
    static let storageKey = "fullDuplexTrace"

    /// Turn tracing off and forget it was ever on. Called from `BackendService.signOut()`.
    static func clearLocal() {
        UserDefaults.standard.removeObject(forKey: storageKey)
        enabled = false
    }

    /// Read once per session rather than per frame — this is on the data-channel
    /// path, and a `UserDefaults` hit per event is not free.
    private static let lock = NSLock()
    private static var enabled = false
    private static var origin = ContinuousClock.now

    static var isOn: Bool {
        lock.lock(); defer { lock.unlock() }
        return enabled
    }

    static func begin() {
        lock.lock()
        enabled = UserDefaults.standard.bool(forKey: storageKey)
        origin = ContinuousClock.now
        let on = enabled
        lock.unlock()
        if on { RealtimeLog.log("trace: data-channel tracing ON") }
    }

    static func note(_ label: String) {
        lock.lock()
        let on = enabled
        let elapsed = ContinuousClock.now - origin
        lock.unlock()
        guard on else { return }
        let ms = Double(elapsed.components.seconds) * 1000
            + Double(elapsed.components.attoseconds) / 1e15
        RealtimeLog.log(String(format: "trace %7.0fms  %@", ms, label))
    }

    /// One line per inbound frame with just the tool and status. Full frames carry mail contents.
    static func inbound(_ frame: Data) {
        guard isOn else { return }
        guard let obj = try? JSONSerialization.jsonObject(with: frame) as? [String: Any],
              let type = obj["type"] as? String else {
            note("← <undecodable frame>")
            return
        }
        var detail = ""
        if let name = obj["name"] as? String { detail += " name=\(name)" }
        if let item = obj["item"] as? [String: Any] {
            let kind = item["type"] as? String ?? "?"
            detail += " item=\(kind)"
            if let name = item["name"] as? String { detail += "/\(name)" }
        }
        if let response = obj["response"] as? [String: Any] {
            if let status = response["status"] as? String { detail += " status=\(status)" }
            if let output = response["output"] as? [[String: Any]] {
                let kinds = output.map { ($0["type"] as? String) ?? "?" }
                detail += " output=[\(kinds.joined(separator: ","))]"
            }
            // Why a response failed: a bad request of ours or a server-side problem.
            if let details = response["status_details"] as? [String: Any] {
                let reason = details["reason"] as? String
                let error = details["error"] as? [String: Any]
                let code = error?["code"] as? String
                let message = error?["message"] as? String
                let parts = [reason, code, message].compactMap { $0 }
                if !parts.isEmpty { detail += " why=(\(parts.joined(separator: " / ")))" }
            }
        }
        note("← \(type)\(detail)")
    }

    static func outbound(_ payload: [String: Any]) {
        guard isOn else { return }
        note("→ \(payload["type"] as? String ?? "?")")
    }
}
