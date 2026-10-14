import XCTest
@testable import CodenameJo

/// `SpokenCommand.match` is the one place a transcript hangs up a live call, so both
/// directions are asserted: the wordings that must end it, and the ordinary sentences
/// that must not.
final class SpokenCommandTests: XCTestCase {

    func testAcceptedWordingsEndTheCall() {
        for said in ["End the chat.", "Hang up.", "end session", "Goodbye.",
                     "end the conversation", "I am done"] {
            XCTAssertEqual(SpokenCommand.match(said), .endCall, said)
        }
    }

    func testNormalizationHandlesCaseWhitespaceAndBothApostrophes() {
        XCTAssertEqual(SpokenCommand.match("   END   THE   CHAT   "), .endCall)
        // The right single quote is the spelling the transcriber returns most often;
        // deleting rather than spacing it is what keeps "I'm" one word.
        XCTAssertEqual(SpokenCommand.match("I\u{2019}m done"), .endCall)
        XCTAssertEqual(SpokenCommand.match("I\u{02BC}m done"), .endCall)
        XCTAssertEqual(SpokenCommand.match("I'm done"), .endCall)
    }

    func testFillerIsStrippedFromBothEndsOnly() {
        XCTAssertEqual(SpokenCommand.match("Okay, I'm done. Thanks."), .endCall)
        XCTAssertEqual(SpokenCommand.match("Please end the chat, thank you."), .endCall)
        // A filler word in the middle is part of a sentence, not politeness around one.
        XCTAssertNil(SpokenCommand.match("end the please chat"))
        // Nothing survives normalization, and an empty phrase is not a match.
        XCTAssertNil(SpokenCommand.match("okay thanks"))
        XCTAssertNil(SpokenCommand.match(""))
        XCTAssertNil(SpokenCommand.match("   "))
    }

    func testWholeUtteranceOnlyNeverASubstring() {
        for said in ["Can you end the chat with Nate?", "Did you end the chat?",
                     "Tell Rob I'm done with the chat.", "I'm done with the report",
                     "hang up on him", "Stop.", "Stop talking.", "Bye.",
                     "That's all for now.", "Mute."] {
            XCTAssertNil(SpokenCommand.match(said), said)
        }
    }

    func testPunctuationIsAWordBoundaryUnlikeAnApostrophe() {
        // "chat.Thanks" must not fuse into one word — but the result is still no
        // match, because "chat" alone is not an accepted wording.
        XCTAssertNil(SpokenCommand.match("chat.Thanks"))
        XCTAssertEqual(SpokenCommand.match("end the chat.Thanks"), .endCall)
    }

    /// The two spellings are written out twice on purpose, and the file says to add a
    /// phrase to both. This is the check that they have not drifted apart: every phrase
    /// the transcriber is biased toward has to be one the matcher accepts, or the bias
    /// is pushing toward a wording that does nothing.
    func testEveryBiasingPhraseIsAcceptedByTheMatcher() {
        XCTAssertFalse(SpokenCommand.biasingPhrases.isEmpty)
        for phrase in SpokenCommand.biasingPhrases {
            XCTAssertEqual(SpokenCommand.match(phrase), .endCall, phrase)
        }
    }

    /// The mail vocabulary is handed to the same analyzer. None of it may hang up a
    /// call — a queue instruction that ended the session is the false end this list is
    /// written to avoid.
    func testNoQueueVocabularyPhraseEndsTheCall() {
        for phrase in SpokenCommand.vocabularyPhrases {
            XCTAssertNil(SpokenCommand.match(phrase), phrase)
        }
    }
}
