import AVFoundation
import Combine
import FactoryKit
import Foundation
import UIKit

@MainActor
final class WatchCompanionService {
    @Injected(\.backend) private var backend
    @Injected(\.realtimeService) private var realtime
    @Injected(\.voiceCall) private var coordinator
    @Injected(\.accountBootstrap) private var bootstrap
    @Injected(\.watchAudioRouter) private var router
    private var callID: UUID?
    private var owner: String?
    private var driver: WatchVoiceInputDriver?
    private var started = false
    private var lastWatchPacket = Date()
    private var dialStarted = Date()
    private var hasConnected = false
    private var connectedAt: Date?
    private var receivedAudio = false
    private var muteRevision: UInt64 = 0
    private var lastWatchAudio = Date()
    private var timer: AnyCancellable?
    private var subscriptions = Set<AnyCancellable>()
    private lazy var link: WatchLink = WatchLink(onPacket: { [weak self] packet in
        DispatchQueue.main.async { self?.receive(packet) }
    }, onFailure: { [weak self] id, message in
        Task { @MainActor in
            guard let self, let id, self.callID == id else { return }
            self.finish(error: message)
        }
    }, onReachability: { [weak self] reachable in
        Task { @MainActor in
            guard let self, !reachable, self.callID != nil else { return }
            self.finish(error: "The Watch disconnected. Move closer to your iPhone and try again.")
        }
    })

    func start() {
        guard !started else { return }
        started = true
        link.activate()
        backend.$isSignedIn.combineLatest(backend.$userId)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] signedIn, userID in
                guard let self, self.callID != nil, !signedIn || self.owner != userID else { return }
                self.finish(error: "Your iPhone account changed. Sign in and start a new call.")
            }.store(in: &subscriptions)
    }

    private func receive(_ packet: WatchPacket) {
        if packet.kind == .hello {
            link.send(WatchPacket(kind: .state, status: "idle",
                                 message: backend.isSignedIn ? "Tap to talk to Jo" : "Sign in to Jo on your iPhone first."))
            return
        }
        if packet.kind == .start, let id = packet.callID {
            if callID == id { publish(); return }
            begin(id)
            return
        }
        guard let id = callID, packet.callID == id else { return }
        lastWatchPacket = Date()
        switch packet.kind {
        case .audio:
            receivedAudio = true
            lastWatchAudio = Date()
            driver?.accept(packet)
        case .end: finish()
        case .mute:
            guard let revision = packet.sequence, revision > muteRevision else { return }
            muteRevision = revision
            realtime.setConversationMuted(packet.muted ?? false)
            publish()
        case .ping: publish()
        default: break
        }
    }

    private func begin(_ id: UUID) {
        RealtimeLog.log("watch: start requested; iPhone foreground=\(UIApplication.shared.applicationState == .active)")
        guard callID == nil, !realtime.isConversing else {
            reject(id, "End the current Jo call before starting one on your Watch.")
            return
        }
        guard backend.isSignedIn, let user = backend.userId else {
            reject(id, "Open Jo on your iPhone and sign in first.")
            return
        }
        guard AVAudioApplication.shared.recordPermission == .granted else {
            reject(id, "Make one call in Jo on your iPhone to allow microphone access, then try the Watch.")
            return
        }
        callID = id
        owner = user
        hasConnected = false
        connectedAt = nil
        receivedAudio = false
        muteRevision = 0
        lastWatchPacket = Date()
        lastWatchAudio = Date()
        dialStarted = Date()
        let input = WatchVoiceInputDriver(callID: id, link: link) { [weak self] message in
            Task { @MainActor in
                guard self?.callID == id else { return }
                self?.finish(error: message)
            }
        }
        driver = input
        router.install(input)
        bootstrap.start()
        publish()
        timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.tick() }
        Task {
            await realtime.connect()
            guard callID == id else { return }
            coordinator.dial(announcingConnect: false, opening: SessionOpening.none)
        }
    }

    private func tick() {
        guard callID != nil else { return }
        guard Date().timeIntervalSince(lastWatchPacket) < 5 else {
            finish(error: "The Watch stopped responding. Please start a new call.")
            return
        }
        if receivedAudio && Date().timeIntervalSince(lastWatchAudio) >= 5 {
            finish(error: "The Watch stopped sending audio. Please start a new call.")
            return
        }
        if case .error(let message) = realtime.sessionState { finish(error: message); return }
        switch realtime.sessionState {
        case .listening, .processing, .responding:
            if !hasConnected { connectedAt = Date() }
            hasConnected = true
        default: break
        }
        if !receivedAudio, let connectedAt, Date().timeIntervalSince(connectedAt) > 20 {
            finish(error: "The phone connected, but Watch audio did not start. Please try again.")
            return
        }
        if hasConnected && !realtime.isConversing { finish(); return }
        if !hasConnected && Date().timeIntervalSince(dialStarted) > 30 {
            finish(error: "Jo could not connect. Open Jo on your iPhone and try again.")
            return
        }
        publish()
    }

    private func publish() {
        guard let id = callID else { return }
        let status: String
        switch realtime.sessionState {
        case .listening: status = "listening"
        case .responding: status = "speaking"
        case .processing: status = "working"
        default: status = "connecting"
        }
        link.send(WatchPacket(kind: .state, callID: id, sequence: muteRevision,
                             muted: realtime.isMuted, status: status))
    }

    private func reject(_ id: UUID, _ message: String) {
        link.send(WatchPacket(kind: .state, callID: id, status: "error", message: message))
    }

    private func finish(error: String? = nil) {
        guard let id = callID else { return }
        callID = nil
        owner = nil
        timer = nil
        driver?.close()
        driver = nil
        router.install(nil)
        if realtime.isConversing { realtime.endConversation() }
        link.clear(callID: id)
        link.send(WatchPacket(kind: .state, callID: id,
                             status: error == nil ? "ended" : "error", message: error))
        RealtimeLog.log("watch: call ended\(error.map { ": \($0)" } ?? "")")
    }
}
