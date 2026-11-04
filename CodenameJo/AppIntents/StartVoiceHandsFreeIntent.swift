import AppIntents
import AVFoundation
import FactoryKit
import SwiftUI
import UIKit

/// "Hey Siri, start Jo" — works with the phone locked.
///
/// `StartVoiceSessionIntent` opens the app, and opening an app on a locked phone means Face ID
/// first. This one asks for a background launch instead (`LiveActivityIntent`), tells the system
/// it records audio (`AudioRecordingIntent`, whose rule is that a Live Activity is up while it
/// records), and dials from `perform()` the way the CarPlay launch does, because a background
/// launch has no `CommandView` to consume `pendingLaunch`. It keeps awaiting until the Lock Screen
/// card is up or the dial fails: the system stops the process once `perform()` returns, and only
/// the call's audio session holds it up after that.
///
/// Unlocked, it opens the app and dials there, like every other entry point. `isProtectedDataAvailable`
/// is the lock signal, and it lags a lock by about ten seconds, so a start inside that window
/// takes the foreground path.
///
/// App target only: the system runs a `LiveActivityIntent` in the app's process, and the dial
/// needs the app's container. Verified on a locked iPhone 17 Pro on 2026-11-03: the card was up
/// 1.6 s after the phrase, with no Face ID.
struct StartVoiceHandsFreeIntent: AudioRecordingIntent, LiveActivityIntent {
    static var title: LocalizedStringResource = "Start Voice Command Hands-Free"
    static var description = IntentDescription(
        "Start a Codename Jo call, even with your phone locked."
    )
    static var supportedModes: IntentModes = [.background, .foreground(.dynamic)]
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    /// Comfortably above a cold dial, below the roughly 30 seconds a Lock Screen start is given.
    private static let deadline: TimeInterval = 25

    @MainActor
    func perform() async throws -> some IntentResult {
        if UIApplication.shared.isProtectedDataAvailable {
            try await continueInForeground(alwaysConfirm: false)
            VoiceSessionLauncher.shared.requestLaunch(source: "siri")
            return .result()
        }

        let start = Date()
        LaunchTiming.armed()
        #if DEBUG
        var run = HandsFreeStartLog.Run(
            at: start,
            locked: true,
            appState: Self.describe(UIApplication.shared.applicationState),
            liveActivitiesEnabled: LiveVoiceActivity.isAvailable
        )
        #endif
        RealtimeLog.log("siri-locked: start — app \(Self.describe(UIApplication.shared.applicationState)), "
            + "live activities \(LiveVoiceActivity.isAvailable)")

        let realtime = Container.shared.realtimeService()
        let liveActivity = Container.shared.liveActivity()
        // What the CarPlay launch does first, for the same reason: no view may ever appear.
        Container.shared.accountBootstrap().start()
        guard Container.shared.backend().isSignedIn else {
            RealtimeLog.log("siri-locked: not signed in")
            return .result()
        }
        Container.shared.voiceCall().beginVoice()

        var outcome = "timed out at \(Int(Self.deadline))s"
        while Date().timeIntervalSince(start) < Self.deadline {
            if liveActivity.isRunning {
                outcome = "card up"
                break
            }
            if case .error(let message) = realtime.sessionState {
                outcome = "dial failed: \(message)"
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
        RealtimeLog.log("siri-locked: \(outcome) after \(elapsedMs)ms — state \(realtime.sessionState.label)")
        #if DEBUG
        run.outcome = outcome
        run.elapsedMs = elapsedMs
        run.sessionState = realtime.sessionState.label
        let audio = AVAudioSession.sharedInstance()
        run.audio = "\(audio.category.rawValue.replacingOccurrences(of: "AVAudioSessionCategory", with: "")), "
            + "input \(audio.isInputAvailable ? "available" : "unavailable"), "
            + "\(audio.currentRoute.inputs.map(\.portType.rawValue).joined(separator: "+"))"
        HandsFreeStartLog.record(run)
        #endif
        return .result()
    }

    private static func describe(_ state: UIApplication.State) -> String {
        switch state {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
    }
}

#if DEBUG
/// Locked starts, kept across launches: a console cannot attach to a launch Siri started.
enum HandsFreeStartLog {
    struct Run: Codable {
        let at: Date
        let locked: Bool
        let appState: String
        let liveActivitiesEnabled: Bool
        var outcome: String?
        var elapsedMs: Int?
        var sessionState: String?
        var audio: String?
    }

    private static let key = "debug.handsFreeStart.runs"

    static var runs: [Run] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Run].self, from: data)) ?? []
    }

    static func record(_ run: Run) {
        let kept = Array(([run] + runs).prefix(20))
        if let data = try? JSONEncoder().encode(kept) { UserDefaults.standard.set(data, forKey: key) }
    }

    static func clear() { UserDefaults.standard.removeObject(forKey: key) }
}

/// Settings → Admin → Locked Siri starts.
struct HandsFreeStartSection: View {
    @State private var runs = HandsFreeStartLog.runs

    var body: some View {
        Section {
            if runs.isEmpty {
                Text("No runs yet. Lock the phone and say \"Hey Siri, start Jo\".")
                    .foregroundStyle(Theme.textTertiary)
            }
            ForEach(Array(runs.enumerated()), id: \.offset) { _, run in
                VStack(alignment: .leading, spacing: 4) {
                    Text(run.outcome ?? "no outcome").font(.headline)
                    Text(run.at.formatted(date: .omitted, time: .standard)
                         + " · \(run.locked ? "locked" : "unlocked") · app \(run.appState)"
                         + " · live activities \(run.liveActivitiesEnabled ? "on" : "off")")
                    Text("\(run.elapsedMs ?? 0)ms · state \(run.sessionState ?? "?")")
                    Text("audio \(run.audio ?? "?")")
                }
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
            }
            if !runs.isEmpty {
                Button("Clear runs", role: .destructive) {
                    HandsFreeStartLog.clear()
                    runs = []
                }
            }
        } header: {
            SettingsRow.header("Locked Siri starts")
        }
        .onAppear { runs = HandsFreeStartLog.runs }
    }
}
#endif
