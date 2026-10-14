import Foundation
import WatchConnectivity

final class WatchLink: NSObject, WCSessionDelegate, @unchecked Sendable {
    private let session = WCSession.default
    private let queue = DispatchQueue(label: "com.kiloforge.jo.watch-link")
    private let onPacket: @Sendable (WatchPacket) -> Void
    private let onFailure: @Sendable (UUID?, String) -> Void
    private let onReachability: @Sendable (Bool) -> Void
    private var pending: [UUID: (UUID, TimeInterval)] = [:]
    private var diagnostic: String?

    init(onPacket: @escaping @Sendable (WatchPacket) -> Void,
         onFailure: @escaping @Sendable (UUID?, String) -> Void,
         onReachability: @escaping @Sendable (Bool) -> Void) {
        self.onPacket = onPacket
        self.onFailure = onFailure
        self.onReachability = onReachability
        super.init()
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        session.delegate = self
        session.activate()
    }

    func waitUntilReachable() async throws {
        for _ in 0..<50 {
            try Task.checkCancellation()
            if session.activationState == .activated, session.isReachable { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw NSError(domain: "WatchLink", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Could not reach Jo on your iPhone. Open the phone app and try again."
        ])
    }

    func send(_ packet: WatchPacket) {
        queue.async { [self] in
            guard session.activationState == .activated, session.isReachable else {
                onFailure(packet.callID, "Open Jo on your nearby iPhone, then try again.")
                return
            }
            let now = ProcessInfo.processInfo.systemUptime
            if packet.kind == .audio {
                guard pending.count < 12, !pending.values.contains(where: { now - $0.1 > 2 }) else {
                    let oldest = pending.values.map { now - $0.1 }.max() ?? 0
                    print("watch-link: audio delivery stalled pending=\(pending.count) oldestSeconds=\(oldest)")
                    onFailure(packet.callID, "Watch audio delivery stalled. Please start a new call.")
                    return
                }
            }
            do {
                let data = try JSONEncoder().encode(packet)
                let token = UUID()
                if packet.kind == .audio, let callID = packet.callID {
                    pending[token] = (callID, now)
                }
                session.sendMessageData(data, replyHandler: { [weak self] _ in
                    self?.queue.async { self?.pending.removeValue(forKey: token) }
                }, errorHandler: { [weak self] error in
                    self?.queue.async {
                        self?.pending.removeValue(forKey: token)
                        self?.onFailure(packet.callID, error.localizedDescription)
                    }
                })
            } catch {
                onFailure(packet.callID, error.localizedDescription)
            }
        }
    }

    func clear(callID: UUID) {
        queue.async { [self] in pending = pending.filter { $0.value.0 != callID } }
    }

    func reportDiagnostic(_ message: String) {
        queue.async { [self] in
            diagnostic = message
            publishDiagnostic()
        }
    }

    private func publishDiagnostic() {
        guard session.activationState == .activated, let diagnostic else { return }
        do {
            try session.updateApplicationContext(["watchDiagnostic": diagnostic, "at": Date().timeIntervalSince1970])
        } catch {
            print("watch-link: diagnostic delivery failed: \(error.localizedDescription)")
        }
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        print("watch-link: activated=\(activationState.rawValue) reachable=\(session.isReachable) error=\(error?.localizedDescription ?? "none")")
        #if os(iOS)
        print("watch-link: paired=\(session.isPaired) installed=\(session.isWatchAppInstalled)")
        #endif
        queue.async { [self] in publishDiagnostic() }
        if let error { onFailure(nil, error.localizedDescription) }
        onReachability(activationState == .activated && session.isReachable)
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        print("watch-link: reachable=\(session.isReachable)")
        onReachability(session.isReachable)
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        if let message = applicationContext["watchDiagnostic"] as? String {
            print("watch-link: counterpart diagnostic: \(message)")
        }
    }

    func session(_ session: WCSession, didReceiveMessageData messageData: Data,
                 replyHandler: @escaping (Data) -> Void) {
        guard messageData.count <= 16_384 else {
            replyHandler(Data())
            onFailure(nil, "The Watch sent an oversized message.")
            return
        }
        do {
            let packet = try JSONDecoder().decode(WatchPacket.self, from: messageData)
            if packet.kind == .start || packet.kind == .end || packet.kind == .hello {
                print("watch-link: received \(packet.kind.rawValue)")
            }
            if packet.kind == .audio, !packet.validAudio {
                onFailure(packet.callID, "The Watch audio packet was invalid.")
            } else {
                onPacket(packet)
            }
        } catch {
            onFailure(nil, "Could not read the Watch message: \(error.localizedDescription)")
        }
        replyHandler(Data())
    }

    #if os(iOS)
    func sessionDidBecomeInactive(_ session: WCSession) { onReachability(false) }
    func sessionDidDeactivate(_ session: WCSession) {
        onReachability(false)
        session.activate()
    }
    #endif
}
