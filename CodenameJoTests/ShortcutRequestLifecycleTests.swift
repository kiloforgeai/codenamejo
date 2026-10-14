import AppIntents
import XCTest
@testable import CodenameJo

@MainActor
final class ShortcutRequestLifecycleTests: XCTestCase {
    func testContactReadKeepsItsSenderAcrossTheShortcutHandoff() throws {
        let runner = ShortcutActionRunner(notificationTrigger: { _ in })
        defer { runner.cancel() }
        runner.readTexts(about: "  Taylor Example  ") { _ in }
        let id = try XCTUnwrap(runner.claimRequest())

        XCTAssertTrue(runner.matches(id))
        XCTAssertEqual(runner.pendingAction, "read")
        XCTAssertEqual(runner.pendingSearchName, "Taylor Example")
        XCTAssertFalse(runner.deliverMessages("Unrelated result", requestID: UUID()))
        XCTAssertEqual(runner.pendingSearchName, "Taylor Example")
    }

    func testMissingContactRequestsOnlyUnreadTexts() throws {
        for about in ["", " \n "] {
            let runner = ShortcutActionRunner(notificationTrigger: { _ in })
            runner.readTexts(about: about) { _ in }
            _ = try XCTUnwrap(runner.claimRequest())
            XCTAssertEqual(runner.pendingAction, "unread")
            XCTAssertEqual(runner.pendingSearchName, "")
            runner.cancel()
        }
    }

    func testContactReadRejectsAnotherSenderBeforeDelivery() throws {
        let runner = ShortcutActionRunner(notificationTrigger: { _ in })
        defer { runner.cancel() }
        runner.readTexts(about: "Taylor") { _ in }
        let id = try XCTUnwrap(runner.claimRequest())
        let taylor = IntentPerson(handle: .init(phoneNumber: "+12025550123"))
        let other = IntentPerson(handle: .init(phoneNumber: "+12025550124"))
        runner.bindReadContact(taylor, requestID: id)

        XCTAssertNoThrow(try runner.validateReadSenders([taylor], bodyCount: 1, transcript: nil, requestID: id))
        XCTAssertThrowsError(try runner.validateReadSenders([taylor, other], bodyCount: 2, transcript: nil, requestID: id))
        XCTAssertThrowsError(try runner.validateReadSenders([], bodyCount: 1, transcript: nil, requestID: id))
        XCTAssertThrowsError(try runner.validateReadSenders([], bodyCount: 0, transcript: "Unlabelled text", requestID: id))
        XCTAssertNoThrow(try runner.validateReadSenders([], bodyCount: 0, transcript: nil, requestID: id))
    }

    func testContactIdentityCannotLeakIntoTheNextRead() throws {
        let runner = ShortcutActionRunner(notificationTrigger: { _ in })
        defer { runner.cancel() }
        let person = IntentPerson(handle: .init(phoneNumber: "+12025550123"))
        runner.readTexts(about: "First") { _ in }
        let oldID = try XCTUnwrap(runner.claimRequest())
        runner.bindReadContact(person, requestID: oldID)
        runner.cancel()
        runner.readTexts(about: "Second") { _ in }
        let newID = try XCTUnwrap(runner.claimRequest())
        runner.bindReadContact(person, requestID: oldID)
        XCTAssertThrowsError(try runner.validateReadSenders([person], bodyCount: 1, transcript: nil, requestID: newID))
    }

    func testFetchingTextDoesNotCompleteSend() throws {
        let runner = ShortcutActionRunner(notificationTrigger: { _ in })
        var result: ShortcutActionRunner.Result?
        runner.sendText(to: "+12025550123", body: "Fixture") { result = $0 }
        let id = try XCTUnwrap(runner.claimRequest())

        XCTAssertNotNil(runner.consumePending(requestID: id))
        XCTAssertNil(result)
        XCTAssertTrue(runner.isPending)
        XCTAssertNil(runner.consumePending(requestID: id))
        XCTAssertTrue(runner.completeSend(requestID: id))
        guard case .some(.completed) = result else { return XCTFail("Expected post-send acknowledgement") }
        XCTAssertFalse(runner.isPending)
    }

    func testDuplicateAutomationCannotClaimOrAcknowledgeBeforeConsumption() throws {
        let runner = ShortcutActionRunner(notificationTrigger: { _ in })
        defer { runner.cancel() }
        runner.sendText(to: "+12025550123", body: "Fixture") { _ in }
        let id = try XCTUnwrap(runner.claimRequest())

        XCTAssertNil(runner.claimRequest())
        XCTAssertFalse(runner.completeSend(requestID: id))
        XCTAssertTrue(runner.isPending)
    }

    func testCancelledReadCannotDeliverIntoNextRead() throws {
        let runner = ShortcutActionRunner(notificationTrigger: { _ in })
        runner.readTexts(about: "First") { _ in }
        let oldID = try XCTUnwrap(runner.claimRequest())
        runner.cancel()
        var secondResult: ShortcutActionRunner.Result?
        runner.readTexts(about: "Second") { secondResult = $0 }
        let newID = try XCTUnwrap(runner.claimRequest())

        XCTAssertFalse(runner.deliverMessages("Old conversation", requestID: oldID))
        XCTAssertNil(secondResult)
        XCTAssertTrue(runner.deliverMessages("", requestID: newID))
        guard case .some(.completed(let output)) = secondResult else { return XCTFail("Expected empty read result") }
        XCTAssertEqual(output, "")
    }

    func testOldCallbackCannotFinishNewSend() throws {
        let runner = ShortcutActionRunner(notificationTrigger: { _ in })
        defer { runner.cancel() }
        runner.sendText(to: "+12025550123", body: "First") { _ in }
        let oldID = try XCTUnwrap(runner.claimRequest())
        runner.cancel()
        runner.sendText(to: "+12025550123", body: "Second") { _ in }
        let newID = try XCTUnwrap(runner.claimRequest())

        let url = try XCTUnwrap(URL(string: "aurex://shortcut/error?requestID=\(oldID)&errorMessage=late"))
        XCTAssertTrue(runner.handle(url))
        XCTAssertTrue(runner.matches(newID))
        XCTAssertNotNil(runner.consumePending(requestID: newID))
    }

    func testNotificationTapWaitsForActivation() async throws {
        var active = false
        let launched = expectation(description: "Matching shortcut launched after activation")
        var launches = 0
        var id: UUID?
        let tappedRunner = ShortcutActionRunner(notificationTrigger: { id = $0 }, applicationIsActive: { active },
            launchShortcut: { _ in launches += 1; launched.fulfill(); return true })
        defer { tappedRunner.cancel() }
        tappedRunner.readTexts { _ in }
        tappedRunner.openFromNotification(requestID: try XCTUnwrap(id))
        XCTAssertEqual(launches, 0)
        active = true
        tappedRunner.flushIfNeeded()
        await fulfillment(of: [launched], timeout: 1)
        XCTAssertEqual(launches, 1)
    }

    func testClaimedRequestClearsQueuedNotificationTap() throws {
        var active = false
        var id: UUID?
        let runner = ShortcutActionRunner(notificationTrigger: { id = $0 }, applicationIsActive: { active },
            launchShortcut: { _ in XCTFail("Claimed work must not launch a duplicate"); return false })
        runner.readTexts { _ in }
        runner.openFromNotification(requestID: try XCTUnwrap(id))
        let claimedID = try XCTUnwrap(runner.claimRequest())
        active = true
        runner.flushIfNeeded()
        XCTAssertTrue(runner.deliverMessages("Fixture", requestID: claimedID))
    }

    func testNewAccountCanStartWorkWithoutReceivingTheOldResult() throws {
        var userID: String? = "first-account"
        var oldResults = 0
        let runner = ShortcutActionRunner(notificationTrigger: { _ in }, currentUserID: { userID })
        runner.sendText(to: "+12025550123", body: "First account") { _ in oldResults += 1 }
        let oldID = try XCTUnwrap(runner.claimRequest())
        userID = nil
        XCTAssertFalse(runner.isPending)
        userID = "second-account"
        var newResult: ShortcutActionRunner.Result?
        runner.readTexts { newResult = $0 }
        let newID = try XCTUnwrap(runner.claimRequest())

        XCTAssertFalse(runner.completeSend(requestID: oldID))
        XCTAssertTrue(runner.deliverMessages("Second account", requestID: newID))
        XCTAssertEqual(oldResults, 0)
        guard case .some(.completed(let output)) = newResult else { return XCTFail("Expected the new account's result") }
        XCTAssertEqual(output, "Second account")
    }

    func testDirectAccountSwitchDiscardsPendingWorkBeforeSendGuard() throws {
        var userID: String? = "first-account"
        let runner = ShortcutActionRunner(notificationTrigger: { _ in }, currentUserID: { userID })
        defer { runner.cancel() }
        runner.readTexts { _ in XCTFail("Do not deliver the old account's result") }
        _ = try XCTUnwrap(runner.claimRequest())
        userID = "second-account"
        runner.sendText(to: "+12025550123", body: "Second account") { _ in }
        let id = try XCTUnwrap(runner.claimRequest())
        XCTAssertEqual(runner.consumePending(requestID: id)?.body, "Second account")
    }

    func testGenericSuccessCannotReplacePostSendAcknowledgement() throws {
        let runner = ShortcutActionRunner(notificationTrigger: { _ in })
        var result: ShortcutActionRunner.Result?
        runner.sendText(to: "+12025550123", body: "Fixture") { result = $0 }
        let id = try XCTUnwrap(runner.claimRequest())
        XCTAssertNotNil(runner.consumePending(requestID: id))
        let url = try XCTUnwrap(URL(string: "aurex://shortcut/success?requestID=\(id)"))

        XCTAssertTrue(runner.handle(url))
        guard case .some(.failed) = result else {
            return XCTFail("Generic shortcut success must not confirm a send")
        }
        XCTAssertFalse(runner.completeSend(requestID: id))
    }

    func testHangupInvalidatesUnconsumedText() throws {
        let runner = ShortcutActionRunner(notificationTrigger: { _ in })
        runner.sendText(to: "+12025550123", body: "Fixture") { _ in }
        let id = try XCTUnwrap(runner.claimRequest())
        runner.cancel()

        XCTAssertNil(runner.consumePending(requestID: id))
        XCTAssertFalse(runner.completeSend(requestID: id))
    }

    func testSendFailureAfterConsumptionStillReachesCaller() throws {
        let runner = ShortcutActionRunner(notificationTrigger: { _ in })
        var result: ShortcutActionRunner.Result?
        runner.sendText(to: "+12025550123", body: "Fixture") { result = $0 }
        let id = try XCTUnwrap(runner.claimRequest())
        XCTAssertNotNil(runner.consumePending(requestID: id))
        runner.fail("Messages refused", requestID: id)

        guard case .some(.failed(let message)) = result else { return XCTFail("Expected shortcut failure") }
        XCTAssertEqual(message, "Messages refused")
        XCTAssertFalse(runner.completeSend(requestID: id))
    }
}
