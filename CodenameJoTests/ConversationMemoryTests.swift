import XCTest
@testable import CodenameJo

/// `ConversationMemory.turns` is what an earlier call is replayed as. Every rule it
/// encodes is a failure it prevents: an error string replayed as speech, a dumped inbox
/// listing eating the budget, a stale answer offered to today's question with nothing to
/// say how old it is. `now` is a parameter, so all of it is checkable without a clock.
final class ConversationMemoryTests: XCTestCase {

    private let epoch = Date(timeIntervalSince1970: 1_767_225_600)   // 2026-01-01 00:00 UTC

    private func record(
        _ question: String, _ answer: String, at offset: TimeInterval,
        status: CommandRecord.CommandStatus = .success
    ) -> CommandRecord {
        CommandRecord(commandText: question, responseText: answer, status: status,
                      issuedAt: epoch.addingTimeInterval(offset))
    }

    func testTurnsAlternateUserThenAssistantOldestFirst() {
        let turns = ConversationMemory.turns(
            from: [record("first?", "first answer", at: 0),
                   record("second?", "second answer", at: 30)],
            now: epoch.addingTimeInterval(30))

        XCTAssertEqual(turns.map(\.role), ["user", "assistant", "user", "assistant"])
        XCTAssertEqual(turns.map(\.text),
                       ["first?", "first answer", "second?", "second answer"])
        XCTAssertEqual(ConversationMemory.exchangeCount(
            from: [record("first?", "first answer", at: 0),
                   record("second?", "second answer", at: 30)],
            now: epoch.addingTimeInterval(30)), 2)
    }

    /// A failed turn carries an error string where the answer goes. Replayed, the model
    /// reads it as something the assistant said — so the whole exchange goes, question
    /// included, rather than the answer alone.
    func testUnsuccessfulAndUnansweredTurnsAreDroppedWholesale() {
        let records = [
            record("failed?", "Server 500", at: 0, status: .failed),
            record("cancelled?", "half an ans", at: 10, status: .cancelled),
            record("pending?", "", at: 20, status: .pending),
            record("answered but silent?", "", at: 30),
            record("kept?", "kept answer", at: 40),
        ]
        let turns = ConversationMemory.turns(from: records, now: epoch.addingTimeInterval(40))

        XCTAssertEqual(turns.map(\.text), ["kept?", "kept answer"])
        XCTAssertFalse(turns.contains { $0.text.contains("Server 500") })
        XCTAssertEqual(ConversationMemory.exchangeCount(
            from: records, now: epoch.addingTimeInterval(40)), 1)
    }

    /// The exchange cap is applied to the answered records, not to the raw log — a long
    /// run of failures must not push real exchanges out of memory.
    func testOnlyTheMostRecentExchangesSurviveTheCap() {
        let total = ConversationMemory.maxExchanges + 2
        let records = (0..<total).map { record("q\($0)", "a\($0)", at: TimeInterval($0)) }
        let turns = ConversationMemory.turns(
            from: records, now: epoch.addingTimeInterval(TimeInterval(total)))

        XCTAssertEqual(turns.count, ConversationMemory.maxExchanges * 2)
        XCTAssertEqual(turns.first?.text, "q2", "the two oldest exchanges are dropped")
        XCTAssertEqual(turns.last?.text, "a\(total - 1)")
    }

    /// One dumped inbox listing would otherwise spend the whole budget on its own.
    func testAnOversizeAnswerIsClippedAtItsOwnCeiling() {
        let long = String(repeating: "x", count: ConversationMemory.maxTurnCharacters + 1)
        let clipped = ConversationMemory.turns(
            from: [record("q", long, at: 0)], now: epoch)[1].text
        XCTAssertEqual(clipped.count, ConversationMemory.maxTurnCharacters + 1)
        XCTAssertTrue(clipped.hasSuffix("…"))
        XCTAssertEqual(clipped.dropLast().count, ConversationMemory.maxTurnCharacters)

        let exact = String(repeating: "x", count: ConversationMemory.maxTurnCharacters)
        let untouched = ConversationMemory.turns(
            from: [record("q", exact, at: 0)], now: epoch)[1].text
        XCTAssertEqual(untouched, exact, "a turn exactly at the ceiling is not clipped")
    }

    /// The budget is spent newest-first and stops at the first exchange that will not fit,
    /// so what survives is what the user is most likely to refer back to.
    func testTheCharacterBudgetKeepsTheNewestExchangesAndStopsAtTheFirstOverrun() {
        // Each kept exchange costs one question character plus a clipped 701-character
        // answer, so eight fit inside 6,000 and the ninth would not.
        let padded = { (index: Int) in
            "r\(index)" + String(repeating: "x", count: ConversationMemory.maxTurnCharacters + 1)
        }
        let records = (0..<10).map { record("q", padded($0), at: TimeInterval($0)) }
        let turns = ConversationMemory.turns(
            from: records, now: epoch.addingTimeInterval(9))

        XCTAssertEqual(turns.count, 16, "eight exchanges fit the 6,000-character budget")
        XCTAssertTrue(turns[1].text.hasPrefix("r2"), "the two oldest are what drop")
        XCTAssertTrue(turns[15].text.hasPrefix("r9"), "the newest is always carried")
        let carried = turns.reduce(0) { $0 + $1.text.count }
        XCTAssertLessThanOrEqual(carried, ConversationMemory.maxCharacters)
    }

    /// "You have 4 unread" was true on Tuesday. The stamp is what stops it being replayed
    /// as though it were true now — and it goes on the question, never on the answer.
    func testOnlyQuestionsOlderThanTheFreshWindowAreStamped() {
        let now = epoch.addingTimeInterval(200_000)
        func question(age: TimeInterval) -> String {
            ConversationMemory.turns(
                from: [record("how many unread?", "four", at: 200_000 - age)], now: now)[0].text
        }

        XCTAssertEqual(question(age: ConversationMemory.freshWindow), "how many unread?",
                       "a turn exactly at the window is still now")
        XCTAssertEqual(question(age: ConversationMemory.freshWindow + 1), "[5m ago] how many unread?")
        XCTAssertEqual(question(age: 3_599), "[59m ago] how many unread?")
        XCTAssertEqual(question(age: 3_600), "[1h ago] how many unread?")
        XCTAssertEqual(question(age: 86_399), "[23h ago] how many unread?")
        XCTAssertEqual(question(age: 86_400), "[1d ago] how many unread?")

        let answer = ConversationMemory.turns(
            from: [record("how many unread?", "four", at: 0)], now: now)[1].text
        XCTAssertEqual(answer, "four", "the assistant's own words are never stamped")
    }

    func testNothingAnsweredCarriesNothing() {
        XCTAssertTrue(ConversationMemory.turns(from: [], now: epoch).isEmpty)
        XCTAssertEqual(ConversationMemory.exchangeCount(from: [], now: epoch), 0)
    }
}
