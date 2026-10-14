import XCTest
@testable import CodenameJo

final class SpokenPhraseBufferTests: XCTestCase {
    func testSentencesBecomePhrasesAndTheTailWaitsForFinish() {
        var buffer = SpokenPhraseBuffer()
        XCTAssertEqual(buffer.append("Three new emails. Sarah wants the budget"), ["Three new emails."])
        XCTAssertEqual(buffer.append(" by Friday! Want me to"), ["Sarah wants the budget by Friday!"])
        XCTAssertEqual(buffer.finish(), "Want me to")
        XCTAssertEqual(buffer.pending, "")
    }

    func testOnlyTheFirstPhraseMayEndAtAClauseBreakWithThreeWords() {
        var buffer = SpokenPhraseBuffer()
        XCTAssertEqual(buffer.append("Hi, there. "), ["Hi, there."])
        XCTAssertEqual(buffer.append("Yes, you have a meeting, and lunch after. "), ["Yes, you have a meeting, and lunch after."])
        var first = SpokenPhraseBuffer()
        XCTAssertEqual(first.append("You have three, all from Sarah. "), ["You have three,", "all from Sarah."])
    }

    func testAWholeReplyAndAnEmptyOne() {
        XCTAssertEqual(SpokenPhraseBuffer.phrases(of: "One.\nTwo? Three"), ["One.", "Two?", "Three"])
        XCTAssertEqual(SpokenPhraseBuffer.phrases(of: "  \n "), [])
    }
}
