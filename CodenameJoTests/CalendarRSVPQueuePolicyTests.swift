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
