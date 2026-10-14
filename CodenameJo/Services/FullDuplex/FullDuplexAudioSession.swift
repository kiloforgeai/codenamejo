import AVFoundation
import UIKit
// WebRTC `RTC…` types come from `WebRTCAliases.swift`.

/// Owns the audio session for a full-duplex call. Goes through `RTCAudioSession` because
/// libwebrtc overwrites category or mode set outside its lock.
@MainActor
final class FullDuplexAudioSession {

    /// How long the mic is live before the assistant's audio starts, so VPIO converges on the
    /// room before there is echo to cancel; otherwise server VAD hears the residual as the user.
    static let vpioPreRoll: Duration = .milliseconds(400)

    private static let routeQueue = AudioQueue()

    private(set) var mode: FullDuplexTuning.VoiceMode
    private var routeObserver: AudioRoute.Observer?
    private var sessionObserver: WebRTCSessionObserver?
    private var proximityObserver: NSObjectProtocol?
    private var isHeldToEar = false
    private var isActivated = false
    var onFailure: ((String) -> Void)?

    /// No `.defaultToSpeaker`, so clearing the speaker override can return output to the receiver.
    static let webRTCCategoryOptions: AVAudioSession.CategoryOptions = [
        .allowBluetooth,
        .allowBluetoothA2DP,
    ]

    init(mode: FullDuplexTuning.VoiceMode) {
        self.mode = mode
        // Our own override emits a route change; reacting to it would loop and reset AEC convergence.
        routeObserver = AudioRoute.Observer(ignoringSelfInflicted: true) { [weak self] in
            MainActor.assumeIsolated { self?.applyOutputRoute() }
        }
        // The route is asserted after libwebrtc configures the session. See `WebRTCSessionObserver`.
        sessionObserver = WebRTCSessionObserver(onSessionConfigured: { [weak self] in
            MainActor.assumeIsolated { self?.applyOutputRoute() }
        }, onFailure: { [weak self] message in
            MainActor.assumeIsolated {
                guard let self, self.isActivated else { return }
                self.onFailure?(message)
            }
        })
    }

    /// At the ear, the display turns off and output moves to the receiver; away, back to the loudspeaker.
    private func startProximityMonitoring() {
        guard proximityObserver == nil else { return }
        UIDevice.current.isProximityMonitoringEnabled = true
        isHeldToEar = UIDevice.current.proximityState
        proximityObserver = NotificationCenter.default.addObserver(
            forName: UIDevice.proximityStateDidChangeNotification,
            object: UIDevice.current,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isHeldToEar = UIDevice.current.proximityState
                RealtimeLog.log("audio: phone proximity \(self.isHeldToEar ? "near" : "far")")
                self.applyOutputRoute()
            }
        }
    }

    private func stopProximityMonitoring() {
        if let proximityObserver {
            NotificationCenter.default.removeObserver(proximityObserver)
            self.proximityObserver = nil
        }
        isHeldToEar = false
        UIDevice.current.isProximityMonitoringEnabled = false
    }

    /// The ADM applies this global config when it starts, overwriting any category or mode set
    /// directly. Install before creating the peer connection, which initialises the ADM.
    static func installWebRTCConfiguration(mode: FullDuplexTuning.VoiceMode) {
        let config = RTCAudioSessionConfiguration.webRTC()
        config.category = AVAudioSession.Category.playAndRecord.rawValue
        config.categoryOptions = webRTCCategoryOptions
        config.mode = mode.avMode.rawValue
        RealtimeLog.log("audio: installed libwebrtc session config — mode \(mode.rawValue), receiver-capable")
        RTCAudioSessionConfiguration.setWebRTC(config)
    }

    /// Call before creating the peer connection.
    func activate(mode: FullDuplexTuning.VoiceMode) {
        self.mode = mode
        isActivated = true
        startProximityMonitoring()
        Self.installWebRTCConfiguration(mode: mode)
        // No setCategory/setMode/setActive here: the ADM activates with the config above, and
        // activating before the ADM exists can keep VPIO out of the graph.
        RealtimeLog.log("audio: deferring session activation to libwebrtc — mode \(mode.rawValue)")

        // iOS silences haptics while recording unless told otherwise.
        try? AVAudioSession.sharedInstance()
            .setAllowHapticsAndSystemSoundsDuringRecording(true)
    }

    /// `.voiceChat` ignores `.defaultToSpeaker`, so the override is required; clear it with `.none`
    /// when an accessory connects, since an override survives route changes.
    func applyOutputRoute(onSettled: (() -> Void)? = nil) {
        guard isActivated else { onSettled?(); return }
        // A connected accessory always wins. With only the phone available, use
        // its receiver at the ear and its loudspeaker everywhere else.
        let heldToEar = isHeldToEar
        Self.routeQueue.detached("call output route") {
            let rtc = RTCAudioSession.sharedInstance()
            rtc.lockForConfiguration()
            defer {
                rtc.unlockForConfiguration()
                if let onSettled { DispatchQueue.main.async(execute: onSettled) }
            }
            let force = AudioRoute.shouldForceBuiltInSpeaker(isHeldToEar: heldToEar)

            // Required: the override itself fires a route change that calls back here, and each
            // route change reinitialises the audio unit and discards VPIO's convergence.
            guard force != AudioRoute.isOnBuiltInSpeaker else { return }
            do {
                try rtc.overrideOutputAudioPort(force ? .speaker : .none)
                RealtimeLog.log("audio: route → \(AudioRoute.describeCurrentRoute())")
            } catch {
                RealtimeLog.log("audio: output route failed — \(error.localizedDescription)")
            }
        }
    }

    func deactivate(onSettled: (() -> Void)? = nil) {
        guard isActivated else { onSettled?(); return }
        isActivated = false
        stopProximityMonitoring()
        // Shared with route assertions across dials so an old release cannot overtake a new one.
        Self.routeQueue.detached("release call output route") {
            let rtc = RTCAudioSession.sharedInstance()
            rtc.lockForConfiguration()
            defer {
                rtc.unlockForConfiguration()
                if let onSettled { DispatchQueue.main.async(execute: onSettled) }
            }
            do {
                try rtc.overrideOutputAudioPort(.none)
            } catch {
                RealtimeLog.log("audio: releasing output route failed — \(error.localizedDescription)")
            }
            // The ADM balances its own activation; this owner never activates RTC.
            RealtimeLog.log("audio: route released; session activation belongs to libwebrtc")
        }
    }

    /// libwebrtc's software APM stages, on top of the hardware canceller. Mandatory so a failure to
    /// apply them is a connection error, not silent echo. Read off the main actor.
    nonisolated static var audioSourceConstraints: RTCMediaConstraints {
        RTCMediaConstraints(
            mandatoryConstraints: [
                "googEchoCancellation": "true",
                "googAutoGainControl": "true",
                "googNoiseSuppression": "true",
                "googHighpassFilter": "true",
            ],
            optionalConstraints: nil)
    }
}

/// Reports when libwebrtc has configured the audio session, which can reset the route to the
/// earpiece, so the output route is re-asserted after it. Delegates are held weakly by libwebrtc.
///
/// Selectors are explicit because every delegate method is `@optional`: a mismatched Swift
/// signature compiles and is never called.
final class WebRTCSessionObserver: NSObject, RTCAudioSessionDelegate {

    private let onSessionConfigured: () -> Void
    private let onFailure: (String) -> Void
    /// The ADM starts play and record separately, so this fires more than once a call.
    private var hasLoggedStart = false

    /// Swift imports `addDelegate:`/`removeDelegate:` as `add`/`remove`.
    init(onSessionConfigured: @escaping () -> Void, onFailure: @escaping (String) -> Void) {
        self.onSessionConfigured = onSessionConfigured
        self.onFailure = onFailure
        super.init()
        RTCAudioSession.sharedInstance().add(self)
    }

    deinit {
        RTCAudioSession.sharedInstance().remove(self)
    }

    /// The ADM has started the audio unit and applied its configuration.
    @objc(audioSessionDidStartPlayOrRecord:)
    func audioSessionDidStartPlayOrRecord(_ session: RTCAudioSession) {
        if !hasLoggedStart {
            hasLoggedStart = true
            RealtimeLog.log("audio: libwebrtc started play/record — asserting the output route after it")
        }
        DispatchQueue.main.async(execute: onSessionConfigured)
    }

    /// Activation also reapplies the session configuration. Deactivation is the end of the call
    /// and is ignored.
    @objc(audioSession:didSetActive:)
    func audioSession(_ audioSession: RTCAudioSession, didSetActive active: Bool) {
        guard active else { return }
        DispatchQueue.main.async(execute: onSessionConfigured)
    }

    @objc(audioSession:failedToSetActive:error:)
    func audioSession(_ session: RTCAudioSession, failedToSetActive active: Bool, error: Error) {
        guard active else { return }
        reportFailure("activation", error: error)
    }

    @objc(audioSession:audioUnitStartFailedWithError:)
    func audioSession(_ session: RTCAudioSession, audioUnitStartFailedWithError error: Error) {
        reportFailure("audio unit start", error: error)
    }

    private func reportFailure(_ stage: String, error: Error) {
        let detail = error as NSError
        RealtimeLog.log("audio: \(stage) failed — \(detail.domain)/\(detail.code): \(detail.localizedDescription)")
        DispatchQueue.main.async { [onFailure] in
            onFailure("The microphone and speaker could not start. Please dial again.")
        }
    }
}
