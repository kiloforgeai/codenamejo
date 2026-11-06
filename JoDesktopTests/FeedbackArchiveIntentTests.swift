import XCTest
@testable import CodenameJo

final class FeedbackArchiveIntentTests: XCTestCase {
    func testExplicitArchiveBeforeFeedbackIsSeparated() {
        for text in ["Great. You can archive it. I want to give some feedback.",
                     "Archive this email and then log feedback: the screen is cramped",
                     "Please archive it; log feedback: the text is small"] {
            XCTAssertNotNil(LiveRequestRecovery.feedbackAfterArchive(text), text)
        }
    }

    func testFeedbackComplaintsNegationsAndQuotedActionsAreNotAuthorization() {
        for text in ["Feedback: you archived the wrong email", "Don't archive it. I want to give feedback",
                     "I said archive it. Feedback: it failed", "\"Archive it\". I want to give feedback",
                     "Archive it. Actually don't, I want to give feedback", "Archive it", "I want to give feedback. Archive it",
                     "Great. You can", "archive", "Archive all emails. Feedback: too slow"] {
            XCTAssertNil(LiveRequestRecovery.feedbackAfterArchive(text), text)
        }
    }
}
