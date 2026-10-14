import XCTest
@testable import CodenameJo

final class SuggestedActionFastPathTests: XCTestCase {
    func testSenderAddressIsTheBareAddressOrNothing() {
        XCTAssertEqual(FullDuplexVoiceClient.senderAddress("LinkedIn News <News@LinkedIn.com>"), "news@linkedin.com")
        XCTAssertEqual(FullDuplexVoiceClient.senderAddress("deals@shop.example.com"), "deals@shop.example.com")
        XCTAssertNil(FullDuplexVoiceClient.senderAddress("Shop Team"))
        XCTAssertNil(FullDuplexVoiceClient.senderAddress("a <not an address>"))
    }

    func testSenderNameDropsQuotes() {
        XCTAssertEqual(FullDuplexVoiceClient.senderName("\"Brooks Brothers\" <hello@email.example.com>"), "Brooks Brothers")
        XCTAssertNil(FullDuplexVoiceClient.senderName("hello@email.example.com"))
    }

    @MainActor func testOnlyAYesAcceptsTheOffer() {
        XCTAssertEqual(SuggestedActionTracker.answer(to: "Yeah, go ahead"), .accepted)
        XCTAssertEqual(SuggestedActionTracker.answer(to: "Sure"), .accepted)
        XCTAssertEqual(SuggestedActionTracker.answer(to: "No, just archive this one"), .declined)
        XCTAssertNil(SuggestedActionTracker.answer(to: "Okay, next"))
    }
}
