import XCTest
@testable import CodenameJo

final class CalendarRSVPQueuePolicyTests: XCTestCase {
    func testRecognizesOnlyExplicitRSVPChoices() {
        XCTAssertEqual(
            CalendarRSVPQueuePolicy.response(in: "Can you accept this invite, please?"),
            "accepted")
        XCTAssertEqual(
            CalendarRSVPQueuePolicy.response(in: "Decline that invitation"),
            "declined")
        XCTAssertNil(CalendarRSVPQueuePolicy.response(in: "Say maybe to this one"))
        XCTAssertNil(CalendarRSVPQueuePolicy.response(in: "What time is this invite?"))
        XCTAssertNil(CalendarRSVPQueuePolicy.response(in: "Yes"))
        XCTAssertNil(CalendarRSVPQueuePolicy.response(
            in: "That time is unacceptable; what else works?"))
    }

    func testBindsTheEventToTheEmailOnScreen() {
        XCTAssertTrue(CalendarRSVPQueuePolicy.matchesInvitation(
            eventSummary: "hi test",
            eventAccount: "raghav@example.com",
            emailSubject: "Invitation: hi test @ Sat Sep 5, 2026",
            emailAccount: "RAGHAV@example.com"))
        XCTAssertFalse(CalendarRSVPQueuePolicy.matchesInvitation(
            eventSummary: "another event",
            eventAccount: "raghav@example.com",
            emailSubject: "Invitation: hi test @ Sat Sep 5, 2026",
            emailAccount: "raghav@example.com"))
        XCTAssertFalse(CalendarRSVPQueuePolicy.matchesInvitation(
            eventSummary: "hi test",
            eventAccount: "work@example.com",
            emailSubject: "Invitation: hi test @ Sat Sep 5, 2026",
            emailAccount: "raghav@example.com"))
    }

    func testTreatsQueuedAndAlreadyHeldAnswersAsAcceptedByTheBroker() {
        XCTAssertTrue(CalendarRSVPQueuePolicy.brokerAccepted(
            output: "Accepted \"hi test\" as raghav@example.com.",
            response: "accepted", brokerVerdict: nil))
        XCTAssertTrue(CalendarRSVPQueuePolicy.brokerAccepted(
            output: "\"hi test\" was already accepted on raghav@example.com.",
            response: "accepted", brokerVerdict: nil))
        XCTAssertFalse(CalendarRSVPQueuePolicy.brokerAccepted(
            output: "No event id — list the calendar first.",
            response: "accepted", brokerVerdict: nil))
        XCTAssertFalse(CalendarRSVPQueuePolicy.brokerAccepted(
            output: "Accepted \"hi test\" as raghav@example.com.",
            response: "accepted", brokerVerdict: false))
    }

    func testCalendarDecisionCannotBeMisreadAsEndingTheCall() {
        XCTAssertTrue(CalendarRSVPQueuePolicy.refusesEndSession(
            for: "You decline hi test for me, please?"))
        XCTAssertTrue(CalendarRSVPQueuePolicy.refusesEndSession(
            for: "Accept that invitation"))
        XCTAssertFalse(CalendarRSVPQueuePolicy.refusesEndSession(
            for: "Say maybe to this one"))
        XCTAssertFalse(CalendarRSVPQueuePolicy.refusesEndSession(
            for: "Decline the invite, then hang up"))
        XCTAssertFalse(CalendarRSVPQueuePolicy.refusesEndSession(
            for: "I'm done for now"))
    }
}
