import XCTest
@testable import CodenameJo

/// How a tool name is routed once it arrives: stripped of its server prefix, turned
/// into a label and a glyph, read for a refusal, and checked for whether the queue
/// chip has to move. `ToolNarration.canonical` is the shared step, and the whole point
/// of it being shared is that these two callers cannot disagree.
final class ToolRoutingTests: XCTestCase {

    // MARK: - canonical

    func testAdvertisedPrefixesAreStrippedAndOtherNamesAreLeftAlone() {
        XCTAssertEqual(ToolNarration.canonical("gmail_search_messages"), "search_messages")
        XCTAssertEqual(ToolNarration.canonical("github_merge_pull_request"), "merge_pull_request")
        // Only the leading prefix, and only these two.
        XCTAssertEqual(ToolNarration.canonical("notion-fetch"), "notion-fetch")
        XCTAssertEqual(ToolNarration.canonical("search_messages"), "search_messages")
        XCTAssertEqual(ToolNarration.canonical("read_gmail_thread"), "read_gmail_thread")
        XCTAssertEqual(ToolNarration.canonical(""), "")
    }

    /// A prefixed name has to reach the same phrasing as the bare one, because the
    /// failure this guards is a wire format being read out where a clause belongs.
    func testPrefixedNamesNarrateAsTheBareToolAndNeverAsAWireFormat() {
        for tool in ["search_messages", "send_email", "archive_message"] {
            XCTAssertEqual(
                ToolNarration.progressLabel(for: "gmail_" + tool),
                ToolNarration.progressLabel(for: tool), tool)
            XCTAssertEqual(
                ToolNarration.doneLabel(for: "gmail_" + tool),
                ToolNarration.doneLabel(for: tool), tool)
        }
        let label = ToolNarration.progressLabel(for: "gmail_search_messages")
        XCTAssertFalse(label.contains("_"), label)
        XCTAssertFalse(label.contains("gmail"), label)
        // An unmapped tool still reads as something rather than nothing.
        XCTAssertEqual(ToolNarration.doneLabel(for: "gmail_future_tool"), "future tool")
    }

    // MARK: - sourceIcon

    func testIconPrecedenceKeepsTheSpecificTestsAheadOfTheSubstringBuckets() {
        // The context cache, ahead of the mail bucket.
        XCTAssertEqual(ToolNarration.sourceIcon(for: "search_context"), "brain")
        XCTAssertEqual(ToolNarration.sourceIcon(for: "save_context"), "brain")
        XCTAssertEqual(ToolNarration.sourceIcon(for: "list_profiles"), "person.crop.circle.fill")
        // Exact where the word is common: the web is not every tool containing "search".
        XCTAssertEqual(ToolNarration.sourceIcon(for: "web_search"), "globe")
        XCTAssertEqual(
            ToolNarration.sourceIcon(for: "search_code"),
            "chevron.left.forwardslash.chevron.right")
        XCTAssertEqual(
            ToolNarration.sourceIcon(for: "github_merge_pull_request"),
            "chevron.left.forwardslash.chevron.right")
        // The Gmail tools that are deliberately not envelopes.
        XCTAssertEqual(ToolNarration.sourceIcon(for: "read_attachment"), "paperclip")
        XCTAssertEqual(ToolNarration.sourceIcon(for: "gmail_read_attachment"), "paperclip")
        XCTAssertEqual(
            ToolNarration.sourceIcon(for: "create_mailbox_filter"),
            "line.3.horizontal.decrease.circle")
        // …and the ones that are.
        XCTAssertEqual(ToolNarration.sourceIcon(for: "gmail_get_thread"), "envelope")
        XCTAssertEqual(ToolNarration.sourceIcon(for: "find_person"), "envelope")
        XCTAssertEqual(ToolNarration.sourceIcon(for: "create_calendar_event"), "calendar")
        // Unknown is nil rather than a wrong service.
        XCTAssertNil(ToolNarration.sourceIcon(for: "future_tool"))
    }

    // MARK: - isRefusal

    func testARefusalIsReadFromHowTheSentenceOpensAndNowhereElse() {
        XCTAssertTrue(ToolNarration.isRefusal("NOT SENT — no address for Nate"))
        XCTAssertTrue(ToolNarration.isRefusal("  not saved — the draft was empty"))
        XCTAssertTrue(ToolNarration.isRefusal("No subject — nothing to send"))
        XCTAssertTrue(ToolNarration.isRefusal("Couldn't reach Gmail"))
        XCTAssertTrue(ToolNarration.isRefusal("There is no draft on that thread"))
        // A success receipt that merely mentions one of the markers later on. A false
        // positive here would draw a warning on a write that actually happened.
        XCTAssertFalse(ToolNarration.isRefusal("Sent to nate@example.test; there is no cc"))
        XCTAssertFalse(ToolNarration.isRefusal("Nothing left in the queue"))
        XCTAssertFalse(ToolNarration.isRefusal("Note: archived 4 messages"))
        XCTAssertFalse(ToolNarration.isRefusal(""))
    }

    // MARK: - Which tools move the queue chip

    @MainActor
    func testQueueAdvanceUsesTheSameCanonicalNameAndKeepsItsOmissions() {
        // Prefixed or bare, one answer — two copies of the prefix rule would disagree.
        XCTAssertTrue(TriageQueueStore.advancesQueue("archive_message"))
        XCTAssertTrue(TriageQueueStore.advancesQueue("gmail_archive_message"))
        XCTAssertTrue(TriageQueueStore.advancesQueue("unsubscribe_sender"))
        XCTAssertTrue(TriageQueueStore.advancesQueue("create_calendar_event"))
        XCTAssertTrue(TriageQueueStore.advancesQueue("send_draft"))
        // Absent on purpose: the broker moves no cursor for these, and listing one
        // would count a step the queue never took.
        XCTAssertFalse(TriageQueueStore.advancesQueue("unarchive_message"))
        XCTAssertFalse(TriageQueueStore.advancesQueue("archive_matching"))
        XCTAssertFalse(TriageQueueStore.advancesQueue("update_calendar_event"))
        XCTAssertFalse(TriageQueueStore.advancesQueue("cancel_calendar_event"))
        XCTAssertFalse(TriageQueueStore.advancesQueue("search_messages"))
        XCTAssertFalse(TriageQueueStore.advancesQueue(""))
    }

    @MainActor
    func testTheChipTakesTheDevicesOwnPositionAndBothWaysOfClearingItEmptyIt() {
        let store = TriageQueueStore()
        XCTAssertNil(store.progress)

        store.applyLocal(LocalTriageQueue.Progress(
            account: "work@example.test", position: 1, queued: 12, remaining: 12, done: false))
        XCTAssertEqual(store.progress?.account, "work@example.test")
        XCTAssertEqual(store.progress?.position, 1)
        // The item being spoken has not been dealt with yet, so it is still remaining.
        XCTAssertEqual(store.progress?.remaining, 12)
        XCTAssertEqual(store.progress?.done, false)

        store.applyLocal(LocalTriageQueue.Progress(
            account: "work@example.test", position: 12, queued: 12, remaining: 0, done: true))
        XCTAssertEqual(store.progress?.done, true)

        store.applyLocal(nil)
        XCTAssertNil(store.progress)

        store.applyLocal(LocalTriageQueue.Progress(
            account: nil, position: 3, queued: 5, remaining: 3, done: false))
        XCTAssertNil(store.progress?.account)
        store.clear()
        XCTAssertNil(store.progress)
    }
}
