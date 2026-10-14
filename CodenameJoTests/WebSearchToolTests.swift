import XCTest
@testable import CodenameJo

/// The phone's `web_search`: the guards that answer before any request leaves the device.
final class WebSearchToolTests: XCTestCase {
    func testCalendarOperationsAreRefusedWhileCalendarResearchStaysSearchable() {
        XCTAssertTrue(WebSearchTool.calendarRefusal("create a calendar event 4 PM today review email")?
            .hasPrefix("NOT SEARCHED —") == true)
        XCTAssertNil(WebSearchTool.calendarRefusal("how to create a Google Calendar event"))
        XCTAssertNil(WebSearchTool.calendarRefusal("what opened in Montréal today"))
    }

    func testCitationMarkersAreStrippedAndOtherBracketsKept() {
        XCTAssertEqual(WebSearchTool.stripCitations("  Montréal opened today [12][14]. Keep [draft] intact.  "),
                       "Montréal opened today. Keep [draft] intact.")
        XCTAssertEqual(WebSearchTool.stripCitations("[1][2]"), "")
    }

    func testRefusalsAnswerWithoutAKey() async {
        let empty = await WebSearchTool.run(argumentsJSON: #"{"query":"  "}"#, interactiveCoaching: false)
        XCTAssertTrue(empty.failed)
        let coaching = await WebSearchTool.run(argumentsJSON: #"{"query":"weather","user_requested":false}"#,
                                               interactiveCoaching: true)
        XCTAssertFalse(coaching.failed)
        XCTAssertTrue(coaching.output.hasPrefix("NOT SEARCHED —"))
    }
}
