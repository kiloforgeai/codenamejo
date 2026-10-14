import Foundation
import Combine

/// Bridges external entry points to the in-app microphone: an intent flips a flag, `CommandView`
/// consumes it. Keeps `static let shared` for the extension; app code uses `\.voiceLauncher`.
@MainActor
final class VoiceSessionLauncher: ObservableObject {
    static let shared = VoiceSessionLauncher()
    private init() {}

    /// True when something outside the UI asked Jo to start listening. `CommandView` connects and
    /// starts capture once the session reaches `.ready`.
    @Published var pendingLaunch = false

    /// True when something outside the UI asked for an offline note instead of a call. Consumed by
    /// `CommandView` through the voice-notes gate.
    @Published var pendingMemo = false

    /// Which surface asked, for the dial's analytics event. A `String` because this file compiles
    /// into the extension; read at service time, never observed.
    private(set) var launchSource = "launch"

    /// - Parameter source: `control`, `action-button`, `siri`, `shortcut`, `onboarding`
    ///   or `resume`.
    func requestLaunch(source: String = "launch") {
        launchSource = source
        // The press, and the origin of every launch figure; every external entry point funnels
        // through here.
        LaunchTiming.armed()
        pendingLaunch = true
    }

    /// Does not arm `LaunchTiming`: a note never dials.
    func requestMemo() {
        pendingMemo = true
    }

    func consume() {
        pendingLaunch = false
    }

    func consumeMemo() {
        pendingMemo = false
    }
}
