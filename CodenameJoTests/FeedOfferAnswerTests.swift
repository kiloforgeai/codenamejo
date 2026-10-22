import XCTest
@testable import CodenameJo

final class FeedOfferAnswerTests: XCTestCase {
    @MainActor func testOnlyAYesAcceptsTheOffer() {
        XCTAssertEqual(FeedOfferAnswer.answer(to: "Yeah, go ahead"), .accepted)
        XCTAssertEqual(FeedOfferAnswer.answer(to: "Sure"), .accepted)
        XCTAssertEqual(FeedOfferAnswer.answer(to: "No, just archive this one"), .declined)
        XCTAssertNil(FeedOfferAnswer.answer(to: "Okay, next"))
    }
}
