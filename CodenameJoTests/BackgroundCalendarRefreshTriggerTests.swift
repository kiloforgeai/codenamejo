import XCTest
@testable import CodenameJo

final class BackgroundCalendarRefreshTriggerTests: XCTestCase {
    func testCalendarWritesMatchWithAndWithoutServerPrefix() {
        XCTAssertTrue(BackgroundCalendarRefresh.isCalendarWrite("create_calendar_event"))
        XCTAssertTrue(BackgroundCalendarRefresh.isCalendarWrite("update_calendar_event"))
        XCTAssertTrue(BackgroundCalendarRefresh.isCalendarWrite("cancel_calendar_event"))
        XCTAssertTrue(BackgroundCalendarRefresh.isCalendarWrite("respond_to_calendar_event"))
        XCTAssertTrue(BackgroundCalendarRefresh.isCalendarWrite("aurex_create_calendar_event"))
    }

    func testCalendarReadsAndOtherToolsDoNotMatch() {
        XCTAssertFalse(BackgroundCalendarRefresh.isCalendarWrite("list_calendar_events"))
        XCTAssertFalse(BackgroundCalendarRefresh.isCalendarWrite("search_calendar"))
        XCTAssertFalse(BackgroundCalendarRefresh.isCalendarWrite("create_draft"))
        XCTAssertFalse(BackgroundCalendarRefresh.isCalendarWrite(""))
    }
}
