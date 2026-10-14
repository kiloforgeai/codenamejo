// coverage-target: CodenameJo/Services/PushNotifications.swift

import UserNotifications
import XCTest

@testable import CodenameJo

/// The one place that decides whether this phone may show a notification.
///
/// The file's own header says why the three-way answer matters: the system prompt can be
/// shown exactly once per install, so a screen has to tell "never asked" (offer to ask)
/// from "denied" (send them to iOS Settings) from "authorised". `isEnabled` and `canAsk`
/// are that distinction, and collapsing either one produces a button that does nothing.
///
/// Nothing here touches `UNUserNotificationCenter`: `status` is set directly, and the one
/// method exercised — `request()` — is exercised only on the branch that returns before
/// it would raise a prompt.
@MainActor
final class PushAuthorizationStateTests: XCTestCase {

    // MARK: - The starting point

    func testAFreshServiceHasNotAskedAnythingYet() {
        let push = PushNotifications()
        XCTAssertEqual(push.status, .notDetermined,
                       "`.notDetermined` is the honest starting value — nothing has been asked")
        XCTAssertFalse(push.isRequesting)
        XCTAssertTrue(push.canAsk, "Never asked is the one state where asking shows a prompt")
        XCTAssertFalse(push.isEnabled, "An alert sent before the grant would be dropped")
    }

    // MARK: - What each answer means

    func testAuthorizedMeansAnAlertWouldAppearAndThereIsNothingLeftToAsk() {
        let push = PushNotifications()
        push.status = .authorized
        XCTAssertTrue(push.isEnabled)
        XCTAssertFalse(push.canAsk, "A second ask after a grant shows nothing")
    }

    func testProvisionalStillCountsAsEnabledEvenThoughNobodyWasAsked() {
        let push = PushNotifications()
        push.status = .provisional
        XCTAssertTrue(push.isEnabled,
                      "Provisional delivers quietly — an alert sent now does appear")
        XCTAssertFalse(push.canAsk,
                       "The answer is already on file, so the prompt is spent")
    }

    func testEphemeralCountsAsEnabled() {
        let push = PushNotifications()
        push.status = .ephemeral
        XCTAssertTrue(push.isEnabled)
        XCTAssertFalse(push.canAsk)
    }

    func testDeniedIsNeitherEnabledNorAskable() {
        let push = PushNotifications()
        push.status = .denied
        XCTAssertFalse(push.isEnabled, "Nothing sent to a denied install reaches a screen")
        XCTAssertFalse(push.canAsk,
                       "iOS Settings is the only place a denial can be changed; offering to "
                       + "ask again is a button that does nothing")
    }

    /// The boundary this pair exists for: exactly one status offers the prompt, and it is
    /// not the same set as the statuses that deliver.
    func testOnlyNeverAskedOffersThePromptAcrossEveryStatus() {
        let push = PushNotifications()
        for status in [UNAuthorizationStatus.notDetermined, .denied, .authorized,
                       .provisional, .ephemeral] {
            push.status = status
            XCTAssertEqual(push.canAsk, status == .notDetermined,
                           "canAsk must track .notDetermined alone, not \(status.rawValue)")
        }
    }

    func testEnabledCoversTheThreeDeliveringStatusesAndNoOthers() {
        let push = PushNotifications()
        var delivering: Set<Int> = []
        for status in [UNAuthorizationStatus.notDetermined, .denied, .authorized,
                       .provisional, .ephemeral] {
            push.status = status
            if push.isEnabled { delivering.insert(status.rawValue) }
        }
        XCTAssertEqual(
            delivering,
            Set([UNAuthorizationStatus.authorized.rawValue,
                 UNAuthorizationStatus.provisional.rawValue,
                 UNAuthorizationStatus.ephemeral.rawValue]))
    }

    // MARK: - A second tap while the prompt is up

    func testASecondRequestWhileThePromptIsUpIsRefusedWithoutAsking() async {
        let push = PushNotifications()
        push.status = .denied
        push.isRequesting = true

        let answer = await push.request()

        XCTAssertEqual(answer, .denied,
                       "The guarded path answers with what is currently believed")
        XCTAssertTrue(push.isRequesting,
                      "The in-flight ask owns the flag; the refused one must not clear it")
    }

    func testTheRefusedRequestReportsWhicheverStatusIsCurrentlyBelieved() async {
        let push = PushNotifications()
        push.status = .provisional
        push.isRequesting = true

        let answer = await push.request()

        XCTAssertEqual(answer, .provisional)
    }
}
