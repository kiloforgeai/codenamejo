import AVFoundation

/// Where the spoken reply should come out. Force the loudspeaker only when nothing else is connected:
/// `overrideOutputAudioPort(.speaker)` overrides accessories, while `.defaultToSpeaker` yields to them.
enum AudioRoute {

    /// Whether to force the built-in loudspeaker. A whitelist of built-in ports, so any new port type
    /// (something the user connected) wins by default.
    static func shouldForceBuiltInSpeaker(outputs: [AVAudioSession.Port]) -> Bool {
        guard !outputs.isEmpty else { return true }
        return outputs.allSatisfy { $0 == .builtInSpeaker || $0 == .builtInReceiver }
    }

    /// Accessories always win; with only built-in ports, speakerphone is used only while the
    /// proximity sensor says the phone is away from the ear.
    static func shouldForceBuiltInSpeaker(
        outputs: [AVAudioSession.Port],
        isHeldToEar: Bool
    ) -> Bool {
        !isHeldToEar && shouldForceBuiltInSpeaker(outputs: outputs)
    }

    static func shouldForceBuiltInSpeaker(isHeldToEar: Bool) -> Bool {
        shouldForceBuiltInSpeaker(
            outputs: AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portType),
            isHeldToEar: isHeldToEar)
    }

    /// Whether output is on the loudspeaker. `AVAudioSession` has no getter for the override, and a redundant
    /// override fires a route change that resets the audio unit and its echo canceller.
    static var isOnBuiltInSpeaker: Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs
            .contains { $0.portType == .builtInSpeaker }
    }

    /// The current output ports, for logs and the diagnostics screen.
    static func describeCurrentRoute() -> String {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        guard !outputs.isEmpty else { return "none" }
        return outputs.map { friendlyName(for: $0.portType) }.joined(separator: ", ")
    }

    /// Re-applies the route when the hardware changes, since an override outlives the route it was set for.
    /// `ignoringSelfInflicted` drops `.override` only; in a call `.categoryChange` is libwebrtc's and must be heard.
    final class Observer {
        private var token: NSObjectProtocol?

        init(ignoringSelfInflicted: Bool = false, onChange: @escaping () -> Void) {
            token = NotificationCenter.default.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: nil,
                queue: nil
            ) { note in
                let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                let reason = raw.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
                if ignoringSelfInflicted, reason == .override {
                    return
                }
                RealtimeLog.log("audio: route changed (\(AudioRoute.name(for: reason))) "
                    + "→ \(AudioRoute.describeCurrentRoute())")
                DispatchQueue.main.async(execute: onChange)
            }
        }

        deinit {
            if let token { NotificationCenter.default.removeObserver(token) }
        }
    }

    /// Readable route-change reasons, so the log says why the route moved rather
    /// than printing an integer that has to be looked up.
    static func name(for reason: AVAudioSession.RouteChangeReason?) -> String {
        switch reason {
        case .newDeviceAvailable: return "device connected"
        case .oldDeviceUnavailable: return "device disconnected"
        case .categoryChange: return "category change"
        case .override: return "override"
        case .wakeFromSleep: return "wake from sleep"
        case .noSuitableRouteForCategory: return "no suitable route"
        case .routeConfigurationChange: return "route reconfigured"
        case .unknown: return "unknown"
        case .some(let other): return "reason \(other.rawValue)"
        case .none: return "unspecified"
        }
    }

    /// Port names a person would recognise. The raw values are things like
    /// `BluetoothHFP`, which is accurate and tells a user nothing.
    static func friendlyName(for port: AVAudioSession.Port) -> String {
        switch port {
        case .builtInSpeaker: return "iPhone speaker"
        case .builtInReceiver: return "Earpiece"
        case .headphones: return "Wired headphones"
        case .bluetoothA2DP, .bluetoothLE: return "Bluetooth"
        case .bluetoothHFP: return "Bluetooth headset"
        case .carAudio: return "Car audio"
        case .airPlay: return "AirPlay"
        case .usbAudio: return "USB audio"
        case .HDMI: return "HDMI"
        default: return port.rawValue
        }
    }
}
