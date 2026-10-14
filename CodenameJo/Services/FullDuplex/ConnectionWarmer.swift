import Foundation

/// Pre-opens TCP+TLS on `URLSession.shared` so the first request of a call skips the handshake (~320 ms).
/// The pool belongs to the session, so this must use the same `URLSession.shared` the callers use.
enum ConnectionWarmer {

    /// Gmail's first `messages.get` of a call otherwise pays DNS+TCP+TLS inside a blocking `triage_next`.
    /// The path never resolves; a credential-free request 401s, which is all the handshake needs.
    private static func targets() -> [URL] {
        var urls: [URL] = []
        if let gmail = URL(
            string: "https://www.googleapis.com/gmail/v1/users/me/messages/notfound")
        {
            urls.append(gmail)
        }
        return urls
    }

    /// The pool reaps idle connections, so re-warm once the last warm-up is this old.
    private static let interval: TimeInterval = 120
    private nonisolated(unsafe) static var lastWarmedAt: Date?
    private static let lock = NSLock()

    /// Fire and forget; failures leave us where every dial already starts.
    static func warm() {
        lock.lock()
        if let last = lastWarmedAt, Date().timeIntervalSince(last) < interval {
            lock.unlock()
            return
        }
        lastWarmedAt = Date()
        lock.unlock()

        for url in targets() {
            Task.detached(priority: .utility) {
                var req = URLRequest(url: url)
                // HEAD with a short timeout: only the handshake matters.
                req.httpMethod = "HEAD"
                req.timeoutInterval = 5
                let started = ContinuousClock.now
                _ = try? await URLSession.shared.data(for: req)
                let ms = Int(started.duration(to: .now) / .milliseconds(1))
                RealtimeLog.log("warm: \(url.host() ?? "?") connection ready in \(ms)ms")
            }
        }
    }
}
