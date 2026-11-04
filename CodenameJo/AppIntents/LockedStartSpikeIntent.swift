#if DEBUG
import AppIntents
import AVFoundation
import FactoryKit
import SwiftUI
import UIKit

/// Spike: can Siri start a call with the phone locked? Debug builds only.
///
/// Unlike `StartVoiceSessionIntent`, this never opens the app. It asks the system for a background
/// launch (`LiveActivityIntent`, `supportedModes = .background`), says it records audio
/// (`AudioRecordingIntent`), and dials from inside `perform()` the way the CarPlay launch does,
/// because a background launch has no `CommandView` to consume `pendingLaunch`. It keeps awaiting
/// until the Lock Screen card is up or the dial fails: the system stops the process once
/// `perform()` returns, and only a live audio session holds it up after that.
///
/// What the open question is: Apple documents that the card must be up while recording, and says
/// nothing about whether the microphone may start on a locked phone. Each run writes what it saw
/// to `LockedStartSpikeLog`, shown in Settings → Admin → Locked start spike.
struct LockedStartSpikeIntent: AudioRecordingIntent, LiveActivityIntent {
    static var title: LocalizedStringResource = "Test Jo Locked (Spike)"
    static var description = IntentDescription(
        "Debug spike: start a call without opening the app, to test the phone locked."
    )
    static var supportedModes: IntentModes = .background
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    /// Comfortably above a cold dial, below the roughly 30 seconds a Lock Screen start is given.
    private static let deadline: TimeInterval = 25

    @MainActor
    func perform() async throws -> some IntentResult {
        let start = Date()
        var run = LockedStartSpikeLog.Run(
            at: start,
            locked: !UIApplication.shared.isProtectedDataAvailable,
            appState: Self.describe(UIApplication.shared.applicationState),
            liveActivitiesEnabled: LiveVoiceActivity.isAvailable
        )
        RealtimeLog.log("locked-spike: perform — locked \(run.locked), app \(run.appState), "
            + "live activities \(run.liveActivitiesEnabled)")

        let realtime = Container.shared.realtimeService()
        let liveActivity = Container.shared.liveActivity()
        // What the CarPlay launch does first, for the same reason: no view may ever appear.
        Container.shared.accountBootstrap().start()
        guard Container.shared.backend().isSignedIn else {
            run.outcome = "not signed in"
            LockedStartSpikeLog.record(run)
            return .result()
        }
        Container.shared.voiceCall().beginVoice()

        while Date().timeIntervalSince(start) < Self.deadline {
            if liveActivity.isRunning {
                run.outcome = "card up"
                break
            }
            if case .error(let message) = realtime.sessionState {
                run.outcome = "dial failed: \(message)"
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        if run.outcome == nil { run.outcome = "timed out at \(Int(Self.deadline))s" }
        run.elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
        run.sessionState = realtime.sessionState.label
        let audio = AVAudioSession.sharedInstance()
        run.audio = "\(audio.category.rawValue.replacingOccurrences(of: "AVAudioSessionCategory", with: "")), "
            + "input \(audio.isInputAvailable ? "available" : "unavailable"), "
            + "\(audio.currentRoute.inputs.map(\.portType.rawValue).joined(separator: "+"))"
        LockedStartSpikeLog.record(run)
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

/// The spike's results, kept across launches: a console cannot attach to a launch Siri started.
enum LockedStartSpikeLog {
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

    private static let key = "spike.lockedStart.runs"

    static var runs: [Run] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Run].self, from: data)) ?? []
    }

    static func record(_ run: Run) {
        RealtimeLog.log("locked-spike: \(run.outcome ?? "?") after \(run.elapsedMs ?? 0)ms — "
            + "state \(run.sessionState ?? "?"), audio \(run.audio ?? "?")")
        let kept = Array(([run] + runs).prefix(20))
        if let data = try? JSONEncoder().encode(kept) { UserDefaults.standard.set(data, forKey: key) }
    }

    static func clear() { UserDefaults.standard.removeObject(forKey: key) }
}

/// Settings → Admin → Locked start spike.
struct LockedStartSpikeSection: View {
    @State private var runs = LockedStartSpikeLog.runs

    var body: some View {
        Section {
            if runs.isEmpty {
                Text("No runs yet. Lock the phone and say \"Test Jo locked\".")
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
                    LockedStartSpikeLog.clear()
                    runs = []
                }
            }
        } header: {
            SettingsRow.header("Locked start spike")
        }
        .onAppear { runs = LockedStartSpikeLog.runs }
    }
}
#endif
