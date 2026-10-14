import AVFoundation
import Combine
import FactoryKit
import Foundation
import WatchKit

@MainActor
class WatchCallService: ObservableObject {
    @Published var status = "idle"
    @Published var message = "Keep your iPhone nearby"
    @Published var active = false
    @Published var muted = false
    @Injected(\.watchAudio) private var audio
    private var callID: UUID?
    private var activated = false
    private var requestedPhone = false
    private var startingAudio = false
    private var audioReady = false
    private var muteRevision: UInt64 = 0
    private var lastPhonePacket = Date()
    private var heartbeat: AnyCancellable?
    private lazy var link: WatchLink = WatchLink(onPacket: { [weak self] packet in
        DispatchQueue.main.async { self?.receive(packet) }
    }, onFailure: { [weak self] id, error in
        Task { @MainActor in
            guard let self, id == self.callID else { return }
            if self.active { self.end(error: error) }
            else { self.message = error }
        }
    }, onReachability: { [weak self] reachable in
        Task { @MainActor in
            guard let self else { return }
            if reachable { self.link.send(WatchPacket(kind: .hello)) }
            else if self.active && self.requestedPhone { self.end(error: "The iPhone disconnected. Keep it nearby and try again.") }
            else if self.status != "error" { self.message = "Open Jo on your nearby iPhone" }
        }
    })

    func activate() {
        guard !activated else { return }
        activated = true
        link.activate()
    }

    func begin() {
        guard callID == nil else { return }
        let id = UUID()
        callID = id
        active = true
        requestedPhone = false
        startingAudio = false
        audioReady = false
        muted = false
        muteRevision = 0
        status = "connecting"
        message = "Connecting to your iPhone…"
        link.reportDiagnostic("Watch call requested; checking microphone permission")
        Task { [self] in
            let allowed = await AVAudioApplication.requestRecordPermission()
            guard callID == id else { return }
            guard allowed else { end(error: WatchAudioError.microphone.localizedDescription); return }
            do {
                link.reportDiagnostic("Watch waiting for iPhone connection")
                try await link.waitUntilReachable()
                guard callID == id else { return }
                lastPhonePacket = Date()
                link.reportDiagnostic("Watch requesting phone session before starting local audio")
                requestedPhone = true
                link.send(WatchPacket(kind: .start, callID: id))
                heartbeat = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
                    .sink { [weak self] _ in self?.tick() }
            } catch {
                guard callID == id else { return }
                end(error: error.localizedDescription)
            }
        }
    }

    private func startAudio(for id: UUID) {
        guard !startingAudio, !audioReady else { return }
        startingAudio = true
        Task { [self] in
            do {
                let connection = link
                link.reportDiagnostic("Phone connected; Watch activating microphone and speaker")
                try await audio.start(callID: id, send: { connection.send($0) }) { [weak self] message in
                    Task { @MainActor in
                        guard self?.callID == id else { return }
                        self?.end(error: message)
                    }
                }
                guard callID == id else { return }
                audioReady = true
                audio.setMuted(muted)
                audio.beginSending()
                link.reportDiagnostic("Watch microphone and speaker running")
                WKInterfaceDevice.current().play(.start)
            } catch {
                guard callID == id else { return }
                end(error: error.localizedDescription)
            }
        }
    }

    func toggleMute() {
        guard let id = callID else { return }
        muted.toggle()
        muteRevision += 1
        audio.setMuted(muted)
        link.send(WatchPacket(kind: .mute, callID: id, sequence: muteRevision, muted: muted))
    }

    func end(error: String? = nil, notifyPhone: Bool = true) {
        guard let id = callID else { return }
        callID = nil
        active = false
        requestedPhone = false
        heartbeat = nil
        audio.stop()
        link.clear(callID: id)
        if notifyPhone { link.send(WatchPacket(kind: .end, callID: id)) }
        status = error == nil ? "idle" : "error"
        message = error ?? "Tap to talk to Jo"
        if let error { link.reportDiagnostic("Watch call failed: \(error)") }
        muted = false
        WKInterfaceDevice.current().play(error == nil ? .stop : .failure)
    }

    private func tick() {
        guard let id = callID else { return }
        guard Date().timeIntervalSince(lastPhonePacket) < 6 else {
            end(error: "Your iPhone stopped responding. Open Jo on your phone and try again.")
            return
        }
        link.send(WatchPacket(kind: .ping, callID: id))
    }

    private func receive(_ packet: WatchPacket) {
        guard let id = callID else {
            if status != "error", packet.kind == .state, packet.callID == nil,
               let message = packet.message { self.message = message }
            return
        }
        guard packet.callID == id else { return }
        lastPhonePacket = Date()
        if packet.kind == .audio {
            guard audioReady else { return }
            audio.play(packet) { [weak self] message in
                Task { @MainActor in
                    guard self?.callID == id else { return }
                    self?.end(error: message)
                }
            }
            return
        }
        guard packet.kind == .state, let status = packet.status else { return }
        if status == "error" || status == "ended" {
            end(error: packet.message, notifyPhone: false)
            return
        }
        if status == "listening" || status == "working" || status == "speaking" {
            startAudio(for: id)
        }
        self.status = audioReady ? status : "connecting"
        if let muted = packet.muted, (packet.sequence ?? 0) >= muteRevision {
            self.muted = muted
            audio.setMuted(muted)
        }
        message = ""
    }
}
