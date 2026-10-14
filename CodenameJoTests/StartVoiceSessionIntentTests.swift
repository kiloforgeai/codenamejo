// coverage-target: Shared/StartVoiceSessionIntent.swift

import XCTest
@testable import CodenameJo

/// The Action Button, the Lock Screen control, Siri and the Shortcuts app all arrive
/// here. The intent has to run in the app's process and leave two facts behind: that a
/// call was asked for, and that it was asked for from outside the UI — which is what
/// separates an external press (which also paid for a process launch) from an orb tap.
@MainActor
final class StartVoiceSessionIntentTests: XCTestCase {

    override func tearDown() async throws {
        VoiceSessionLauncher.shared.consume()
        VoiceSessionLauncher.shared.consumeMemo()
        try await super.tearDown()
    }

    func testPerformRaisesAPendingLaunch() async throws {
        let launcher = VoiceSessionLauncher.shared
        launcher.consume()
        XCTAssertFalse(launcher.pendingLaunch)

        _ = try await StartVoiceSessionIntent().perform()

        XCTAssertTrue(launcher.pendingLaunch)
    }

    /// The dial's analytics event is billed to the surface that asked. `control` is the
    /// one this intent speaks for.
    func testPerformRecordsControlAsTheLaunchSource() async throws {
        let launcher = VoiceSessionLauncher.shared
        launcher.requestLaunch(source: "resume")
        XCTAssertEqual(launcher.launchSource, "resume")

        _ = try await StartVoiceSessionIntent().perform()

        XCTAssertEqual(launcher.launchSource, "control")
    }

    /// Consuming the request is what `CommandView` does once it has dialled; the source
    /// is read at that moment and deliberately survives the flag being cleared.
    func testConsumingTheLaunchLeavesTheSourceReadable() async throws {
        let launcher = VoiceSessionLauncher.shared
        _ = try await StartVoiceSessionIntent().perform()

        launcher.consume()

        XCTAssertFalse(launcher.pendingLaunch)
        XCTAssertEqual(launcher.launchSource, "control")
    }

    /// A call is not a note. The two flags are consumed by different code paths, and a
    /// press that raised both would start a recording over a dialling call.
    func testPerformDoesNotRequestAMemo() async throws {
        let launcher = VoiceSessionLauncher.shared
        launcher.consumeMemo()

        _ = try await StartVoiceSessionIntent().perform()

        XCTAssertFalse(launcher.pendingMemo)
    }

    /// The Realtime session needs the microphone and the foreground process, so this
    /// intent must never be allowed to run silently in the background.
    func testTheIntentAlwaysOpensTheApp() {
        XCTAssertTrue(StartVoiceSessionIntent.openAppWhenRun)
    }
}
