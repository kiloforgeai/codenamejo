import XCTest
@testable import CodenameJo

/// `Conversation.group` decides what History draws as one call and, through
/// `resumableId`, which id a resumed dial is minted under. PRINCIPLES rule 14 lives here:
/// a thread whose records were never tagged has no conversation to resume, and `id` is a
/// stand-in for `Identifiable` rather than an answer.
final class ConversationGroupingTests: XCTestCase {

    private let epoch = Date(timeIntervalSince1970: 1_767_225_600)   // 2026-01-01 00:00 UTC

    private func record(
        _ text: String, at offset: TimeInterval, conversation: UUID? = nil,
        status: CommandRecord.CommandStatus = .success
    ) -> CommandRecord {
        CommandRecord(
            commandText: text, responseText: "ok", status: status,
            issuedAt: epoch.addingTimeInterval(offset), conversationId: conversation)
    }

    func testTaggedTurnsGroupUnderTheirOwnIdNewestConversationFirst() {
        let first = UUID(), second = UUID()
        let groups = Conversation.group([
            record("one", at: 0, conversation: first),
            record("two", at: 60, conversation: first),
            record("three", at: 120, conversation: second),
        ])

        XCTAssertEqual(groups.map(\.id), [second, first], "newest conversation first")
        XCTAssertEqual(groups.last?.records.map(\.commandText), ["one", "two"],
                       "records inside a conversation stay oldest first")
        XCTAssertEqual(groups.last?.exchangeCount, 2)
        XCTAssertEqual(groups.last?.title, "one", "the opening question names the thread")
        XCTAssertEqual(groups.last?.duration, 60)
        XCTAssertEqual(groups.last?.lastActivity, epoch.addingTimeInterval(60))
    }

    /// Input arrives from a PostgREST fetch in no guaranteed order, so the sort is the
    /// first thing `group` does — a shuffled page must produce the same threads.
    func testUnorderedInputIsSortedBeforeGrouping() {
        let id = UUID()
        let groups = Conversation.group([
            record("last", at: 120, conversation: id),
            record("first", at: 0, conversation: id),
            record("middle", at: 60, conversation: id),
        ])

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].records.map(\.commandText), ["first", "middle", "last"])
        XCTAssertEqual(groups[0].title, "first")
        XCTAssertEqual(groups[0].duration, 120)
    }

    /// The whole of rule 14's app-side half: an untagged thread cannot be dialled, and
    /// the `Identifiable` stand-in must never be offered as the id to resume under.
    func testAnUntaggedThreadHasNoResumableIdAndFallsBackToItsFirstRecord() {
        let legacy = record("what did I ask?", at: 0)
        let groups = Conversation.group([legacy])

        XCTAssertEqual(groups.count, 1)
        XCTAssertNil(groups[0].resumableId)
        XCTAssertEqual(groups[0].id, legacy.id, "the stand-in is the record's own id")

        let tagged = UUID()
        let resumable = Conversation.group([record("hello", at: 0, conversation: tagged)])
        XCTAssertEqual(resumable[0].resumableId, tagged)
        XCTAssertEqual(resumable[0].id, tagged)
    }

    /// Untagged records split on a pause instead, and the comparison is `<=` — a gap of
    /// exactly `idleGap` is still the same sitting, one second more is not.
    func testUntaggedRecordsSplitOnlyOnAGapLongerThanTheIdleWindow() {
        let atTheBoundary = Conversation.group([
            record("one", at: 0),
            record("two", at: Conversation.idleGap),
        ])
        XCTAssertEqual(atTheBoundary.count, 1, "a gap of exactly idleGap continues")

        let pastIt = Conversation.group([
            record("one", at: 0),
            record("two", at: Conversation.idleGap + 1),
        ])
        XCTAssertEqual(pastIt.count, 2, "one second past it starts a new conversation")
        XCTAssertEqual(pastIt.map { $0.records.map(\.commandText) }, [["two"], ["one"]])
    }

    /// The pause rule is for legacy rows only: neither kind joins the other, or a
    /// resumable id would be inherited by turns never filed under it.
    func testTaggedAndUntaggedTurnsNeverShareAThreadHoweverCloseTheyAre() {
        let id = UUID()
        let mixed = Conversation.group([
            record("legacy", at: 0),
            record("tagged", at: 1, conversation: id),
            record("legacy again", at: 2),
        ])

        XCTAssertEqual(mixed.map { $0.records.map(\.commandText) },
                       [["legacy again"], ["tagged"], ["legacy"]])
        XCTAssertEqual(mixed.map(\.resumableId), [nil, id, nil])
    }

    /// A single exchange has no span to measure, and is not given a fabricated one.
    func testAnEmptyHistoryGroupsIntoNothingAndASingleExchangeHasNoDuration() {
        XCTAssertTrue(Conversation.group([]).isEmpty)
        let solo = Conversation.group([record("one", at: 0, conversation: UUID())])
        XCTAssertEqual(solo[0].duration, 0)
        XCTAssertEqual(solo[0].exchangeCount, 1)
    }

    /// Grouping is about identity, not outcome: a failed turn belongs to its call.
    func testAFailedTurnStaysInTheConversationItBelongedTo() {
        let id = UUID()
        let groups = Conversation.group([
            record("ask", at: 0, conversation: id),
            record("ask again", at: 30, conversation: id, status: .failed),
        ])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].records.map(\.status), [.success, .failed])
    }
}
