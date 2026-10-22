// coverage-target: CodenameJo/Onboarding/OnboardingWelcomeView.swift
// coverage-target: CodenameJo/Onboarding/Step1SignInView.swift
// coverage-target: CodenameJo/Onboarding/OnboardingMicrophoneView.swift
// coverage-target: CodenameJo/Onboarding/OnboardingSpeechView.swift
// coverage-target: CodenameJo/Onboarding/OnboardingConnectView.swift
// coverage-target: CodenameJo/Onboarding/OnboardingSayItView.swift
// coverage-target: CodenameJo/Onboarding/OnboardingNotificationsView.swift

import AVFAudio
import XCTest

@testable import CodenameJo

/// What each onboarding step believes before anything has happened on it.
///
/// Onboarding is the one flow where the opening state is the whole screen: every step is
/// drawn before its permission has been read, its account profile has landed, or its clip
/// has played, and each of these flags is what the screen claims during that window. Three
/// of them are load-bearing rather than cosmetic — a step that opens mid-request disables
/// the only button on it, a drafts screen that opens "saving" swallows the answer it exists
/// to collect, and a sign-in screen that opens with an error shows a failure nobody caused.
///
/// The interactors are left out on purpose: theirs is the auto-advance, and it is decided by
/// live microphone, speech and notification authorisation plus a real OAuth presenter —
/// none of which is logic this side can settle.
@MainActor
final class OnboardingStepViewModelTests: XCTestCase {

    // MARK: - Welcome

    /// The walked order starts here, and the permission rows below Jo's clip stay shut
    /// until she is halfway through saying what they are for.
    func testTheWelcomeStepOpensAtItsFirstPhaseWithTheRowsStillLocked() {
        let model = OnboardingWelcomeViewModel()

        guard case .start = model.phase else {
            return XCTFail("The welcome step opens on .start, not mid-flow")
        }
        XCTAssertFalse(model.permissionsUnlocked,
                       "The rows unlock on a timer inside the clip, not on arrival")
        XCTAssertFalse(model.isAsking)
        XCTAssertFalse(model.joSpeaking)
    }

    /// `granted` alone cannot tell an untouched row from a denied one, and only an
    /// untouched row is still worth a tap — so both halves start false together.
    func testNeitherPermissionIsGrantedNorEvenAnsweredOnArrival() {
        let model = OnboardingWelcomeViewModel()
        XCTAssertFalse(model.micGranted)
        XCTAssertFalse(model.micAnswered)
        XCTAssertFalse(model.speechGranted)
        XCTAssertFalse(model.speechAnswered)
    }

    func testTheWelcomeStepOpensWithNoFailureAndNothingCoveringIt() {
        let model = OnboardingWelcomeViewModel()
        XCTAssertNil(model.error)
        XCTAssertFalse(model.showingPrivacy)
        XCTAssertFalse(model.showingSelectAllVideo)
        XCTAssertFalse(model.showVolumeAlert,
                       "The volume warning is raised as a clip starts, never before one")
    }

    // MARK: - Sign in

    func testTheSignInStepOpensIdleWithNoFailureNobodyCaused() {
        let model = Step1SignInViewModel()
        XCTAssertFalse(model.isWorking)
        XCTAssertNil(model.error)
        XCTAssertFalse(model.showingPrivacy)
    }

    // MARK: - Microphone and speech

    /// Both permission steps use one flag that is true only while the system alert is up:
    /// the alert is the feedback, so the flag exists to stop a second tap stacking a second
    /// ask, and opening true would disable the button that has not been pressed.
    func testNeitherPermissionStepOpensMidAsk() {
        XCTAssertFalse(OnboardingMicrophoneViewModel().isRequesting)
        XCTAssertFalse(OnboardingSpeechViewModel().isRequesting)
        XCTAssertFalse(OnboardingNotificationsViewModel().isRequesting)
    }

    // MARK: - Connect

    func testTheConnectStepOpensWithNoConsentInFlightAndNoErrorFromTheLastOne() {
        let model = OnboardingConnectViewModel()
        XCTAssertNil(model.busyConnector,
                     "The service owns the in-flight state, so the button cannot open stuck")
        XCTAssertNil(model.error)
        XCTAssertFalse(model.showingPrivacy)
    }

    func testContinueNeedsAGoogleAccountAndNoOtherTool() {
        let model = OnboardingConnectViewModel()
        XCTAssertEqual(model.providers, [.google], "Google is listed before availability is known")
        model.accounts = [.slack: ["Acme"], .notion: ["Acme"]]
        XCTAssertFalse(model.hasMailbox, "Optional tools alone don't unlock Continue")
        model.accounts[.google] = ["a@example.com"]
        XCTAssertTrue(model.hasMailbox)
    }

    // MARK: - Say it

    func testTheSayItStepOpensSilentWithNoSkipOfferedYet() {
        let model = OnboardingSayItViewModel()
        XCTAssertEqual(model.level, 0, accuracy: 0.0001,
                       "The meter starts at the floor, not at an invented level")
        XCTAssertFalse(model.joSpeaking)
        XCTAssertFalse(model.showSkip, "Skip is offered on a timer, after the ask has had time")
        XCTAssertFalse(model.showVolumeAlert)
    }

    /// Nothing on the phone can raise the output volume for the user, so every clip screen
    /// checks and says so. The threshold is deliberately a hair above silence rather than
    /// zero, because a hair above zero is inaudible too.
    func testTheInaudibleThresholdSitsJustAboveSilenceRatherThanAtIt() {
        XCTAssertGreaterThan(OnboardingVolume.low, 0,
                             "A strictly-zero test would pass on a volume nobody can hear")
        XCTAssertEqual(OnboardingVolume.low, 0.1, accuracy: 0.0001)
        XCTAssertEqual(
            OnboardingVolume.isTooLow,
            AVAudioSession.sharedInstance().outputVolume <= OnboardingVolume.low,
            "The warning is read off the session at or below the threshold, inclusive")
    }
}
