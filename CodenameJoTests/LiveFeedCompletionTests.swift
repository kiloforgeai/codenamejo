import XCTest
@testable import CodenameJo

final class LiveFeedCompletionTests: XCTestCase {
    private static func step(nextProfile: String? = "Personal", interstitial: String = "feed") -> String {
        var payload: [String: Any] = ["done": true, "interstitial": interstitial, "calendarDue": false,
                                      "currentProfile": "Work"]
        if let nextProfile { payload["nextProfile"] = nextProfile }
        return String(decoding: try! JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
    }

    func testTheOfferNamesBothProfilesAndTheWrapUpFollowsIt() throws {
        let completion = try XCTUnwrap(LiveFeedCompletion.from(step: Self.step()))
        XCTAssertEqual(completion.question, "That's everything in Work. Would you like to go through Personal?")
        XCTAssertTrue(completion.backendNote.contains("switch_profile with name \"Personal\""))
        XCTAssertEqual(completion.withoutOffer.question, LiveFeedCompletion.wrapUpQuestion)
        XCTAssertTrue(completion.withoutOffer.backendNote.contains("end_session"))
    }

    func testAFeedWithoutANextProfileAsksTheWrapUp() throws {
        let completion = try XCTUnwrap(LiveFeedCompletion.from(step: Self.step(nextProfile: nil)))
        XCTAssertNil(completion.offer)
        XCTAssertEqual(completion.question, LiveFeedCompletion.wrapUpQuestion)
    }

    func testOnlyTheTerminalFeedCarriesAClosingQuestion() {
        XCTAssertNil(LiveFeedCompletion.from(step: Self.step(interstitial: "page")))
        XCTAssertNil(LiveFeedCompletion.from(step: #"{"done":false,"item":{"id":"m1"}}"#))
    }

    /// A feed reached by archive arrives as a receipt with the queue JSON appended.
    func testAFeedBehindASpokenReceiptIsStillRead() throws {
        let completion = try XCTUnwrap(LiveFeedCompletion.from(step: "Archived.\n" + Self.step()))
        XCTAssertEqual(completion.nextProfile, "Personal")
    }

    func testTheAnswerIsReadOnlyOnceTheOfferWasHeard() throws {
        var completion = try XCTUnwrap(LiveFeedCompletion.from(step: Self.step()))
        XCTAssertNil(completion.answer(to: "yes"))
        XCTAssertNil(completion.spoken(in: "Quick tip: say next to move on."))
        XCTAssertEqual(completion.spoken(in: "That's your day. Would you like to go through Personal?"), .offer)
        completion.asked = true
        XCTAssertEqual(completion.answer(to: "Yeah, sure"), .accepted)
        XCTAssertEqual(completion.answer(to: "No thanks"), .declined)
        XCTAssertEqual(completion.answer(to: "archive the last one"), .cancelled)
        XCTAssertNil(completion.answer(to: "Hmm"), "A grunt leaves the offer standing")
        XCTAssertEqual(completion.withoutOffer.spoken(in: LiveFeedCompletion.wrapUpQuestion), .wrapUp)
        XCTAssertNil(completion.withoutOffer.answer(to: "yes"), "The wrap-up answer belongs to the backend")
    }
}
