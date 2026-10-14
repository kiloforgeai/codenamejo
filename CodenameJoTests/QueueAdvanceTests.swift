import XCTest
@testable import CodenameJo

/// `TriageQueueStore.advancesQueue` decides whether the queue chip re-reads its position
/// after a tool lands. It is deliberately a superset, but a false no leaves "3 of 12" on screen while the user has already been moved
/// on, and the number then jumps when the turn ends. The set's own comments argue three
/// specific exclusions, so those are what these pin.
@MainActor
final class QueueAdvanceTests: XCTestCase {

    // MARK: - What moves the cursor

    func testTheToolThatStartsAndStepsAQueueAdvancesIt() {
        XCTAssertTrue(TriageQueueStore.advancesQueue("triage_next"))
    }

    func testAConnectorPrefixIsStrippedBeforeTheComparison() {
        XCTAssertTrue(TriageQueueStore.advancesQueue("gmail_archive_message"))
        XCTAssertTrue(TriageQueueStore.advancesQueue("archive_message"))
    }

    func testEveryFinishingMailWriteAdvancesIt() {
        for tool in ["archive_message", "trash_message", "label_message",
                     "mark_spam", "send_email", "create_draft", "forward_email",
                     "send_draft"] {
            XCTAssertTrue(TriageQueueStore.advancesQueue(tool), tool)
        }
    }

    func testUnsubscribingAndBlockingTimeAdvanceItForTheirOwnReasons() {
        // One carries a message id, the other is gated on the queue being live.
        XCTAssertTrue(TriageQueueStore.advancesQueue("unsubscribe_sender"))
        XCTAssertTrue(TriageQueueStore.advancesQueue("create_calendar_event"))
    }

    // MARK: - What deliberately does not

    func testUnarchivingDoesNotAdvanceItDespiteCarryingAMessageId() {
        // The broker keeps it out of its finishing tools, so no cursor moves and a chip
        // that counted the step would jump back on the next reading.
        XCTAssertFalse(TriageQueueStore.advancesQueue("unarchive_message"))
        XCTAssertFalse(TriageQueueStore.advancesQueue("gmail_unarchive_message"))
    }

    func testTheBulkToolsDoNotAdvanceItBecauseTheyTakeAQueryNotAMessage() {
        for tool in ["archive_matching", "modify_matching", "trash_matching"] {
            XCTAssertFalse(TriageQueueStore.advancesQueue(tool), tool)
        }
    }

    func testTheOtherCalendarToolsStayOffTheList() {
        // Only blocking time is an action on the message being walked; the rest are asides.
        for tool in ["update_calendar_event", "cancel_calendar_event", "list_calendar_events",
                     "respond_to_event"] {
            XCTAssertFalse(TriageQueueStore.advancesQueue(tool), tool)
        }
    }

    func testReadsAndUnknownNamesDoNotAdvanceIt() {
        for tool in ["search_messages", "gmail_search_messages", "read_thread",
                     "search_context", "list_commands", "some_future_tool", ""] {
            XCTAssertFalse(TriageQueueStore.advancesQueue(tool), tool)
        }
    }

    func testAPrefixThatIsNotAConnectorIsNotStripped() {
        // `canonical` knows two prefixes; anything else is a different tool name.
        XCTAssertFalse(TriageQueueStore.advancesQueue("notion_archive_message"))
        XCTAssertFalse(TriageQueueStore.advancesQueue("ARCHIVE_MESSAGE"))
    }
}
