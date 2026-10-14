import FactoryKit
import Foundation
// WebRTC `RTC…` types come from `WebRTCAliases.swift`.

/// What the transport tells the session client about.
enum RealtimeSignal {
    case liveDelegation(String, userTurn: Int)
    case liveFunction(LiveSessionAdapter.Call)
    case liveFarewellFinished
    case liveBackendIdle
    /// The user's turn ended in speech and no delegation was ever created for it.
    case liveTurnIdleWithoutDelegation(speech: String)
    case liveQueueActionUnworked(exhausted: Bool)
    case liveTranscriptFinished
    case liveUserActivity
    case liveInputText(String)
    case liveInputFinished(String)
    /// The user's last word to Jo's first, on Live's timeline.
    case liveFirstSpeech(afterInputMs: Int)
    case liveBackendUsage(ResponseUsage, ms: Int)
    case liveBrainStep(CommandRecord.BrainStep)
    case liveContextUsage(Double)
    case connected
    /// The mic is open and the capture tap running, during the mint and well before `connected`:
    /// the phone can hear the user before OpenAI can.
    case micLive
    case closed(reason: String)
    case failed(String)
    case event(RealtimeEvent)
}

/// Full-duplex WebRTC transport for the OpenAI Realtime API. Not actor-isolated: libwebrtc calls
/// delegates on its own threads, and everything leaves through `signals`.
final class FullDuplexTransport: NSObject {

    var liveAdapter: LiveSessionAdapter?
    let signals: AsyncStream<RealtimeSignal>
    private let emit: AsyncStream<RealtimeSignal>.Continuation

    private static let sslOnce: Void = { _ = RTCInitializeSSL() }()

    /// Records both sides of the call; both audio taps attach here.
    let recorder = SessionRecorder()

    /// Transcribes the user's half on device, from the same capture tap.
    let localTranscriber = LocalTranscriber()

    /// Meters the user's half before WebRTC's `media-source` level exists. See `MicLevelTap`.
    let micMeter = MicLevelTap()

    /// The APM's single capture delegate, forwarding to the above. Held strongly: the APM's property is `weak`.
    private let captureTap = CaptureTapFanout()

    @Injected(\.voiceEvidence) private var validationEvidence
    @Injected(\.voiceInputDriver) private var inputDriver
    @Injected(\.voiceAudioConfiguration) private var audioConfiguration


    /// Built on every call, recorded or not, so recording never changes the capture path.
    /// Assign the delegate via the property: the initialiser argument is silently dropped.
    private lazy var audioProcessing: RTCDefaultAudioProcessingModule = {
        let apm = RTCDefaultAudioProcessingModule(
            config: nil,
            capturePostProcessingDelegate: nil,
            renderPreProcessingDelegate: nil)
        // The slot is single, so the fanout is registered; see `CaptureTapFanout`.
        inputDriver.install(on: captureTap)

        captureTap.add(recorder)
        captureTap.add(localTranscriber)
        captureTap.add(micMeter)
        apm.capturePostProcessingDelegate = captureTap
        return apm
    }()

    private lazy var factory: RTCPeerConnectionFactory = {
        _ = FullDuplexTransport.sslOnce
        // Device calls retain VPIO; injected simulator calls select their audio module in FactoryKit.
        return RTCPeerConnectionFactory(
            audioDeviceModuleType: audioConfiguration.deviceModule,
            bypassVoiceProcessing: audioConfiguration.bypassVoiceProcessing,
            encoderFactory: nil,
            decoderFactory: nil,
            audioProcessingModule: audioProcessing)
    }()

    /// The assistant's track, held so its renderer can be detached on close.
    private var remoteAudioTrack: RTCAudioTrack?
    private let assistantVolume: Double

    @Injected(\.voiceTransportQueue) private var lifecycleQueue
    private var closed = false
    private var peerConnection: RTCPeerConnection?
    private var dataChannel: RTCDataChannel?
    private var localAudioTrack: RTCAudioTrack?
    private var didSignalConnected = false
    /// Events written before the data channel opened, flushed on open.
    private var outbox: [Data] = []

    init(assistantVolume: Double = 1.0) {
        self.assistantVolume = min(max(assistantVolume, 0), 1)
        (signals, emit) = AsyncStream.makeStream(of: RealtimeSignal.self)
        super.init()
    }

    // MARK: - Connect

    /// The offer built by `prepare()`, waiting for a token to hand it to.
    private var pendingOffer: RTCSessionDescription?
    /// When the mic went live, so `finish()` knows how much pre-roll the mint already covered.
    private var micLiveAt: ContinuousClock.Instant?

    /// Everything that needs no token, run during the mint so the VPIO pre-roll overlaps it.
    /// The mic track is attached before the SDP handshake so AEC converges before anything plays.
    func prepare(conversationId: String?) async throws {
        try Task.checkCancellation()
        await inputDriver.prepare()
        try Task.checkCancellation()
        try await audioConfiguration.prepare()

        try Task.checkCancellation()
        let pc = try await lifecycleQueue.run("voice transport preparation") { [self] in
            guard !closed else { throw CancellationError() }
            return try makePeerConnection(conversationId: conversationId)
        }
        try Task.checkCancellation()
        let offer = try await pc.makeOffer()
        try Task.checkCancellation()
        try await pc.apply(local: offer)
        try Task.checkCancellation()
        try await lifecycleQueue.run("voice transport prepared") { [self] in
            guard !closed else { throw CancellationError() }
            pendingOffer = offer
            RealtimeLog.log("webrtc: local description set")
        }
    }

    private func makePeerConnection(conversationId: String?) throws -> RTCPeerConnection {
        try audioConfiguration.configure(factory: factory)
        validationEvidence.record("call.prepare", ["conversationId": conversationId ?? "",
            "audioDeviceModule": audioConfiguration.deviceModule == .audioEngine ? "audioEngine" : "platformDefault",
            "bypassVoiceProcessing": audioConfiguration.bypassVoiceProcessing])
        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan

        guard let pc = factory.peerConnection(
            with: config,
            constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil),
            delegate: self
        ) else {
            throw NSError(domain: "FullDuplexTransport", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Could not create the WebRTC peer connection.",
            ])
        }
        peerConnection = pc
        RealtimeLog.log("webrtc: peer connection created")

        // Before the mic, or the first buffers land behind the write head and are dropped.
        // Only validation runs record; this gates the file, not the audio graph.
        if validationEvidence.runID != nil {
            recorder.start(conversationId: conversationId)
        }

        // Unconditional: this produces on-screen words, not a file.
        localTranscriber.start()

        // Mic in. libwebrtc captures automatically once the track is attached.
        let source = factory.audioSource(with: FullDuplexAudioSession.audioSourceConstraints)
        let track = factory.audioTrack(with: source, trackId: "local_audio")
        pc.add(track, streamIds: ["local_stream"])
        localAudioTrack = track
        micLiveAt = ContinuousClock.now
        RealtimeLog.log("webrtc: local audio track attached — awaiting capture buffers")

        // Events channel: transcripts, tool calls, interruption control.
        if let dc = pc.dataChannel(forLabel: "oai-events", configuration: RTCDataChannelConfiguration()) {
            dc.delegate = self
            dataChannel = dc
        }

        return pc
    }

    /// Apply the Live session's SDP answer. Needs the created session, so it can only
    /// run once OpenAI has answered.
    func finish(preRoll: Duration, live: FullDuplexBroker.LiveConfiguration) async throws {
        guard let pc = peerConnection, pendingOffer != nil, let micLiveAt else {
            throw NSError(domain: "FullDuplexTransport", code: -2, userInfo: [
                NSLocalizedDescriptionKey: "The call was not prepared before it was finished.",
            ])
        }

        // Spend whatever is left of the pre-roll; usually zero since `prepare()` overlaps the mint.
        let elapsed = ContinuousClock.now - micLiveAt
        if elapsed < preRoll {
            let remaining = preRoll - elapsed
            RealtimeLog.log("webrtc: holding handshake \(remaining) for VPIO convergence")
            try await Task.sleep(for: remaining)
        } else {
            RealtimeLog.log("webrtc: audio track has been attached \(elapsed) — setup delay satisfied")
        }
        DialTiming.mark("pre-roll remainder")

        DialTiming.mark("SDP exchange")
        try await pc.apply(remote: RTCSessionDescription(type: .answer, sdp: live.answerSDP))
        RealtimeLog.log("webrtc: remote description set; awaiting ICE")

        // Read the remote track now rather than rely on delegates: `didAddStream:` never fires under
        // Unified Plan, and the receiving transceiver exists once the remote description is set.
        attachRecorderToRemoteTracks(of: pc)
    }

    @MainActor
    func enableLive() {
        liveAdapter = LiveSessionAdapter(wire: { [weak self] payload in self?.sendWire(payload) },
                                         emit: { [weak self] signal in self?.emit.yield(signal) })
        liveAdapter?.prepareConversation()
        inputDriver.start { [weak self] in self?.liveAdapter?.isWorkSettled == true }

    }

    func liveOffer() async throws -> String {
        for _ in 0..<100 {
            if peerConnection?.iceGatheringState == .complete { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard let sdp = peerConnection?.localDescription?.sdp ?? pendingOffer?.sdp else {
            throw URLError(.cannotConnectToHost)
        }
        return sdp
    }

    // MARK: - Outbound

    /// Zeroes the capture buffer and leaves the track enabled; see `CaptureTapFanout.muted`.
    func setMuted(_ muted: Bool, settled: (() -> Void)? = nil) {
        inputDriver.setMuted(muted)

        captureTap.setMuted(muted)
        // Takes effect on the next buffer; `settled` exists because `RealtimeService` waits on it.
        if let settled { DispatchQueue.main.async { settled() } }
        RealtimeLog.log("webrtc: mic \(muted ? "muted" : "unmuted")")
    }

    /// Scale microphone gain; 1.0 is normal. Attenuating rather than muting keeps a real voice,
    /// louder than the echo, above the detection threshold.
    func setMicGain(_ gain: Double) {
        localAudioTrack?.source.volume = gain
    }

    /// Drops audio already buffered locally. `output_audio_buffer.clear` is WebRTC-only and also
    /// truncates, so it is not paired with `conversation.item.truncate`.
    func clearOutputAudio() {
        send(["type": "output_audio_buffer.clear"])
    }

    /// Stop generation. Only needed when *we* cancel (a tap on the orb) — a spoken
    /// interruption is cancelled server-side by `interrupt_response`.
    func cancelResponse() {
        send(["type": "response.cancel"])
    }

    /// Inject a typed turn and ask for a spoken reply.
    func sendUserText(_ text: String) {
        send([
            "type": "conversation.item.create",
            "item": [
                "type": "message",
                "role": "user",
                "content": [["type": "input_text", "text": text]],
            ],
        ])
        createResponse()
    }

    /// The Realtime API's maximum `item.id` length.
    private static let maxItemIdLength = 32

    /// Put out-of-band information into the conversation without asking for a reply.
    /// - Parameter speakerBrief: what the Live speaker gets instead of `text`, since its channel
    ///   chunks anything over 450 bytes; empty sends it nothing. The backend always gets `text`.
    func sendContextItem(_ text: String, role: String, id: String? = nil,
                         speakerBrief: String? = nil, awaitingAcknowledgement: Bool = true) {
        var item: [String: Any] = [
            "type": "message",
            "role": role,
            "content": [["type": "input_text", "text": text]],
        ]
        // Clamped: an over-length id is a fatal session error. Callers keep ids unique within their prefix.
        if let id { item["id"] = String(id.prefix(Self.maxItemIdLength)) }
        var event: [String: Any] = ["type": "conversation.item.create", "item": item]
        if let speakerBrief { event["speaker_brief"] = speakerBrief }
        if !awaitingAcknowledgement { event["await_context_ack"] = false }
        send(event)
    }

    /// Return a function tool's result. The server does not continue on its own; follow with `createResponse()`.
    func sendFunctionOutput(callId: String, output: String) {
        send([
            "type": "conversation.item.create",
            "item": [
                "type": "function_call_output",
                "call_id": callId,
                "output": output,
            ],
        ])
    }

    /// An omitted `tools` inherits the session's catalog; an empty array removes it for this response only.
    static func responseCreatePayload(
        instructions: String? = nil, withoutTools: Bool = false
    ) -> [String: Any] {
        var response: [String: Any] = [:]
        if let instructions { response["instructions"] = instructions }
        if withoutTools {
            response["tools"] = [Any]()
            response["tool_choice"] = "none"
        }
        guard !response.isEmpty else { return ["type": "response.create"] }
        return ["type": "response.create", "response": response]
    }

    /// `instructions` override the session's for this response only. `withoutTools` is for turns whose
    /// result is already in the conversation.
    func createResponse(instructions: String? = nil, withoutTools: Bool = false) {
        send(Self.responseCreatePayload(
            instructions: instructions, withoutTools: withoutTools))
    }

    /// Hand a client event to the Live adapter, which translates it onto the wire.
    func send(_ payload: [String: Any]) {
        guard let liveAdapter else { return }
        Task { @MainActor in liveAdapter.outbound(payload) }
    }

    /// Queues until the channel is open: `sendData` on a connecting channel fails silently.
    private func sendWire(_ payload: [String: Any]) {
        validationEvidence.record("live.outbound", payload)
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        let type = payload["type"] as? String ?? "?"
        FullDuplexTrace.outbound(payload)

        guard let dc = dataChannel, dc.readyState == .open else {
            RealtimeLog.log("webrtc: queued \(type) — channel not open yet")
            outbox.append(data)
            return
        }
        dc.sendData(RTCDataBuffer(data: data, isBinary: false))
    }

    private func flushOutbox() {
        guard let dc = dataChannel, dc.readyState == .open, !outbox.isEmpty else { return }
        RealtimeLog.log("webrtc: flushing \(outbox.count) queued event(s)")
        for data in outbox {
            dc.sendData(RTCDataBuffer(data: data, isBinary: false))
        }
        outbox.removeAll()
    }

    /// Raw WebRTC stats, for the level meters and the echo measurement.
    func statistics() async -> RTCStatisticsReport? {
        guard let pc = peerConnection else { return nil }
        return await withCheckedContinuation { cont in
            pc.statistics { cont.resume(returning: $0) }
        }
    }

    func close(reason: String = "ended") {
        lifecycleQueue.detached("voice transport teardown") { [self] in
            guard !closed else { return }
            closed = true
            closeResources(reason: reason)
        }
    }

    private func closeResources(reason: String) {
        Task { @MainActor in inputDriver.stop() }

        if let liveAdapter { Task { @MainActor in liveAdapter.close() } }
        RealtimeLog.log("webrtc: closing — \(reason)")

        // Detach and finish the recording before teardown, while its timeline is still coherent.
        remoteAudioTrack?.remove(recorder)
        if let remoteAudioTrack { inputDriver.detach(from: remoteAudioTrack) }

        remoteAudioTrack = nil
        // `stop()` finalises the file; validation copies it out, then the original goes.
        if let finished = recorder.stop() {
            validationEvidence.record("call.closed", ["reason": reason, "recording": finished.lastPathComponent])
            validationEvidence.retainRecording(finished) {
                try? FileManager.default.removeItem(at: finished)
            }
        }
        localTranscriber.stop()

        dataChannel?.close()
        peerConnection?.close()
        dataChannel = nil
        peerConnection = nil
        audioConfiguration.close()
        localAudioTrack = nil
        emit.yield(.closed(reason: reason))
        emit.finish()
    }

    // MARK: - Inbound

    fileprivate func handle(frame: Data) {
        validationEvidence.receive(frame)
        FullDuplexTrace.inbound(frame)
        guard let liveAdapter else { return }
        Task { @MainActor in
            inputDriver.receive(frame)

            liveAdapter.receive(frame)
        }
    }

    /// Connection is only announced once — ICE reaching `connected` and the data
    /// channel opening both signal readiness and can arrive in either order.
    fileprivate func signalConnectedOnce() {
        guard liveAdapter == nil, !didSignalConnected else { return }
        didSignalConnected = true
        // Here rather than in the client's handler, which runs a main-actor hop later.
        DialTiming.connected()
        emit.yield(.connected)
    }

    fileprivate func signalFailure(_ message: String) {
        emit.yield(.failed(message))
    }
}

// MARK: - Continuation-wrapped WebRTC async

private extension RTCPeerConnection {
    func makeOffer() async throws -> RTCSessionDescription {
        try await withCheckedThrowingContinuation { cont in
            offer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { sdp, error in
                if let sdp { cont.resume(returning: sdp) }
                else { cont.resume(throwing: error ?? URLError(.cannotParseResponse)) }
            }
        }
    }

    func apply(local sdp: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            setLocalDescription(sdp) { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }
    }

    func apply(remote sdp: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            setRemoteDescription(sdp) { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }
    }
}

// MARK: - RTCPeerConnectionDelegate

extension FullDuplexTransport: RTCPeerConnectionDelegate {
    func peerConnection(_ pc: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ pc: RTCPeerConnection, didRemove stream: RTCMediaStream) {}

    /// Attached here and in `didStartReceivingOn`, since which fires depends on the remote description.
    /// Attaching twice is harmless.
    func peerConnection(_ pc: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        guard let track = stream.audioTracks.first else { return }
        attachRecorder(to: track)
    }

    func peerConnection(_ pc: RTCPeerConnection, didStartReceivingOn transceiver: RTCRtpTransceiver) {
        guard let track = transceiver.receiver.track as? RTCAudioTrack else { return }
        attachRecorder(to: track)
    }

    private func attachRecorder(to track: RTCAudioTrack) {
        guard remoteAudioTrack !== track else { return }
        remoteAudioTrack = track
        track.source.volume = assistantVolume
        track.add(recorder)
        inputDriver.attach(to: track)

        RealtimeLog.log("webrtc: assistant track \(track.trackId) at \(assistantVolume)x; recorder attached")
    }


    /// Attach to every receiving audio track. Idempotent.
    fileprivate func attachRecorderToRemoteTracks(of pc: RTCPeerConnection) {
        let audioTracks = pc.transceivers.compactMap { $0.receiver.track as? RTCAudioTrack }
        guard !audioTracks.isEmpty else {
            RealtimeLog.log("webrtc: WARNING no remote audio track found on \(pc.transceivers.count) transceiver(s) — the assistant channel will be silent")
            return
        }
        for track in audioTracks { attachRecorder(to: track) }
    }
    func peerConnectionShouldNegotiate(_ pc: RTCPeerConnection) {}
    func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ pc: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    func peerConnection(_ pc: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        RealtimeLog.log("webrtc: ICE \(newState.readableName)")
        switch newState {
        case .connected, .completed:
            signalConnectedOnce()
        case .failed:
            signalFailure("The connection failed.")
        case .disconnected:
            // Transient: libwebrtc retries and often recovers.
            RealtimeLog.log("webrtc: ICE disconnected (may recover)")
        default:
            break
        }
    }

    /// Remote (assistant) audio needs no handling — WebRTC plays it out itself.
    func peerConnection(_ pc: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        dataChannel.delegate = self
        self.dataChannel = dataChannel
    }
}

// MARK: - RTCDataChannelDelegate

extension FullDuplexTransport: RTCDataChannelDelegate {
    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        RealtimeLog.log("webrtc: data channel \(dataChannel.readyState.readableName)")
        if dataChannel.readyState == .open {
            flushOutbox()
            signalConnectedOnce()
        }
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard !buffer.isBinary else { return }
        handle(frame: buffer.data)
    }
}

// MARK: - Readable state names

private extension RTCIceConnectionState {
    var readableName: String {
        switch self {
        case .new: return "new"
        case .checking: return "checking"
        case .connected: return "connected"
        case .completed: return "completed"
        case .failed: return "failed"
        case .disconnected: return "disconnected"
        case .closed: return "closed"
        case .count: return "count"
        @unknown default: return "unknown(\(rawValue))"
        }
    }
}

private extension RTCDataChannelState {
    var readableName: String {
        switch self {
        case .connecting: return "connecting"
        case .open: return "open"
        case .closing: return "closing"
        case .closed: return "closed"
        @unknown default: return "unknown(\(rawValue))"
        }
    }
}
