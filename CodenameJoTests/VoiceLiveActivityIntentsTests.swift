// coverage-target: Shared/VoiceLiveActivityIntents.swift

import XCTest
@testable import CodenameJo

/// The two Lock Screen buttons, and the only two things that can reach a running call
/// from outside the app's UI.
///
/// They are `LiveActivityIntent`s so the body runs in the app's process, and they reach
/// the session through `VoiceRemoteControl`'s closures because `Shared/` links none of
/// the app's services. What is checkable here without a call is exactly the part that
/// has gone wrong before: which closure each button calls, that it is *awaited* rather
/// than fired and forgotten — the card write and the ActivityKit dismissal both land
/// after the synchronous work, and the system reclaims this process the moment `perform`
/// returns — and that a press arriving before `AppDelegate` has installed the handlers
/// is survivable rather than a crash on a background relaunch.
@MainActor
final class VoiceLiveActivityIntentsTests: XCTestCase {

    /// The test host is the app, so the handlers may already be installed. Put back
    /// whatever was there rather than clearing them.
    private var installedMute: (@MainActor () async -> Void)?
    private var installedEnd: (@MainActor () async -> Void)?

    override func setUp() async throws {
        try await super.setUp()
        installedMute = VoiceRemoteControl.shared.onToggleMute
        installedEnd = VoiceRemoteControl.shared.onEndSession
    }

    override func tearDown() async throws {
        VoiceRemoteControl.shared.onToggleMute = installedMute
        VoiceRemoteControl.shared.onEndSession = installedEnd
        try await super.tearDown()
    }

    // MARK: - Which button reaches which half of the call

    /// Mute closes the microphone and leaves the call up. A mute that also ended the
    /// session would hang up the call the user muted to stay on.
    func testAMutePressReachesTheMuteHandlerAndNotTheHangUp() async throws {
        var muted = 0
        var ended = 0
        VoiceRemoteControl.shared.onToggleMute = { muted += 1 }
        VoiceRemoteControl.shared.onEndSession = { ended += 1 }

        _ = try await ToggleBackgroundMuteIntent().perform()

        XCTAssertEqual(muted, 1)
        XCTAssertEqual(ended, 0, "Mute must leave the call up — it is not a way to end anything")
    }

    /// End hangs up. It must not route through mute, which would leave a live call with
    /// a closed microphone and a dismissed card — the state nothing on screen can undo.
    func testAnEndPressReachesTheHangUpAndNotTheMute() async throws {
        var muted = 0
        var ended = 0
        VoiceRemoteControl.shared.onToggleMute = { muted += 1 }
        VoiceRemoteControl.shared.onEndSession = { ended += 1 }

        _ = try await EndBackgroundVoiceSessionIntent().perform()

        XCTAssertEqual(ended, 1)
        XCTAssertEqual(muted, 0)
    }

    // MARK: - The await is the feature

    /// `perform` must not return until the handler's own async work has finished. The
    /// mic closes synchronously; saying so on the card is an ActivityKit write, and the
    /// system stops handing this process execution as soon as `perform` returns — a
    /// dropped write is the button that stays reading "Mute" over a muted mic.
    func testAMutePressReturnsOnlyAfterTheHandlerHasFinished() async throws {
        var finished = false
        VoiceRemoteControl.shared.onToggleMute = {
            await Task.yield()
            finished = true
        }

        _ = try await ToggleBackgroundMuteIntent().perform()

        XCTAssertTrue(finished, "Fire-and-forget loses the card write this await exists to keep")
    }

    /// Same contract on End, where the cost is worse: ending tears down the audio
    /// session that keeps a backgrounded process alive, so a dismissal merely scheduled
    /// here races suspension and can leave the card up over a dead call.
    func testAnEndPressReturnsOnlyAfterTheHandlerHasFinished() async throws {
        var finished = false
        VoiceRemoteControl.shared.onEndSession = {
            await Task.yield()
            finished = true
        }

        _ = try await EndBackgroundVoiceSessionIntent().perform()

        XCTAssertTrue(finished)
    }

    // MARK: - Before the app has registered anything

    /// iOS can relaunch the app into the background purely to service a button tap. The
    /// handlers are installed from `AppDelegate`, so a press that beats that line finds
    /// nil — and must do nothing rather than trap.
    func testAMutePressWithNoHandlerInstalledIsASafeNoOp() async throws {
        VoiceRemoteControl.shared.onToggleMute = nil

        _ = try await ToggleBackgroundMuteIntent().perform()
    }

    func testAnEndPressWithNoHandlerInstalledIsASafeNoOp() async throws {
        VoiceRemoteControl.shared.onEndSession = nil

        _ = try await EndBackgroundVoiceSessionIntent().perform()
    }

    /// Mute is a toggle held by the session, not by the intent. Two presses are two
    /// reversals; swallowing the second would leave the user's second tap doing nothing
    /// on a button they tapped precisely because the first appeared not to land.
    func testEveryMutePressIsForwardedRatherThanDeduplicated() async throws {
        var presses = 0
        VoiceRemoteControl.shared.onToggleMute = { presses += 1 }

        _ = try await ToggleBackgroundMuteIntent().perform()
        _ = try await ToggleBackgroundMuteIntent().perform()
        _ = try await ToggleBackgroundMuteIntent().perform()

        XCTAssertEqual(presses, 3)
    }

    // MARK: - What the system is told about them

    /// Both buttons exist so the call can be run without unlocking the phone. Opening
    /// the app would defeat the surface they are drawn on.
    func testNeitherButtonOpensTheApp() {
        XCTAssertFalse(ToggleBackgroundMuteIntent.openAppWhenRun)
        XCTAssertFalse(EndBackgroundVoiceSessionIntent.openAppWhenRun)
    }

    /// Meaningless without a running call and a Live Activity to press them from, so
    /// they stay out of Shortcuts and Spotlight: a shortcut that silently does nothing
    /// is worse than no shortcut. `StartVoiceSessionIntent` is the discoverable door.
    func testNeitherButtonIsOfferedInShortcutsOrSpotlight() {
        XCTAssertFalse(ToggleBackgroundMuteIntent.isDiscoverable)
        XCTAssertFalse(EndBackgroundVoiceSessionIntent.isDiscoverable)
        XCTAssertTrue(StartVoiceSessionIntent.isDiscoverable,
                      "The entry point stays discoverable; only the in-call buttons hide")
    }

    /// The two are pressed inches apart on a Lock Screen. Their titles are what the
    /// system reads out and what an accessibility label falls back to, so they have to
    /// be different and neither may be empty.
    func testTheTwoButtonsNameThemselvesDistinctly() {
        let mute = String(localized: ToggleBackgroundMuteIntent.title)
        let end = String(localized: EndBackgroundVoiceSessionIntent.title)

        XCTAssertFalse(mute.isEmpty)
        XCTAssertFalse(end.isEmpty)
        XCTAssertNotEqual(mute, end)
    }
}
