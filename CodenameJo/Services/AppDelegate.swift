import UIKit
import FactoryKit
import UserNotifications

/// UIKit application delegate bridged into the SwiftUI lifecycle via
/// `@UIApplicationDelegateAdaptor` in CodenameJoApp.swift.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // MARK: - Notification routing
        // First: a notification that launched the app is delivered during launch, so a delegate
        // installed later never hears about that tap.
        PushRouting.install()
        Container.shared.watchCompanion().start()

        Task { @MainActor in Container.shared.backend().dropOrphanedGoogleGrant() }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(didBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )

        // MARK: - Have the unread ready before the first frame
        // Earlier than `didBecomeActive`, which lands after it. The observer above still
        // covers returns to the foreground.
        Task { await BackgroundMailRefresh.run(trigger: .launch) }
        // Same trigger, separate cache and throttle state.
        Task { await BackgroundCalendarRefresh.run(trigger: .launch) }
        #if DEBUG
        if ProcessInfo.processInfo.environment["LOCAL_TOOL_EVAL"] != nil { Task { await LocalToolEval.run() } }
        #endif

        // MARK: - The local call's voice and turn detector
        // Both download on first use, and the local call is what answers when there is no
        // connection — by which point it is too late to fetch them.
        MainActor.assumeIsolated { Container.shared.localSpeech().warm() }
        Task {
            do { try await Container.shared.localTurnDetector().prepare() }
            catch { RealtimeLog.log("local-voice: turn detector unavailable — \(error.localizedDescription)") }
        }

        // MARK: - Live Activity remote control
        // Here, not in a view: iOS can relaunch the app in the background to service a Mute
        // or End tap, before any view exists.
        MainActor.assumeIsolated {
            let realtime = Container.shared.realtimeService()
            let remote = Container.shared.voiceRemoteControl()
            remote.onToggleMute = { await realtime.toggleBackgroundMute() }
            remote.onEndSession = {
                // Awaited so the End intent holds the process open until the card is really gone.
                await realtime.endBackgroundSession(
                    reason: "ended from Live Activity", endingCall: true
                ).value
            }

            // Any activity alive at process launch is an orphan: its call died with the old process.
            // `end()` with no owned activity is exactly this sweep.
            Container.shared.liveActivity().end()
        }

        return true
    }

    @objc private func didBecomeActive() {
        Container.shared.shortcutActions().flushIfNeeded()
        // The morning feed is looked up when the app opens, on the user's key.
        Task { @MainActor in await FeedItems.refreshDue() }

        // MARK: - Have the unread ready before the first question
        // A foreground always runs, unlike a silent push. Fire-and-forget so launch isn't slowed;
        // `launchThrottle` keeps app-switching cheap.
        Task { await BackgroundMailRefresh.run(trigger: .launch) }
        Task { await BackgroundCalendarRefresh.run(trigger: .launch) }
    }
}
