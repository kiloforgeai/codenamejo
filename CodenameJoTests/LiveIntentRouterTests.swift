import XCTest
@testable import CodenameJo

final class LiveIntentRouterTests: XCTestCase {
    func testWordsMustNameTheAction() {
        let cases: [(String, LiveFastAction, LiveFastAction?)] = [
            ("Yeah, go ahead", .trash, nil),
            ("Same thing here as well", .trash, nil),
            ("Yeah, that's correct", .trash, nil),
            ("garbage", .spam, nil),
            ("this", .trash, nil),
            ("Yeah, just get rid of this", .trash, nil),
            ("Toss it", .trash, nil),
            ("Just delete it, please", .trash, .trash),
            ("This is junk", .spam, .spam),
            ("Let's move along", .next, .next),
            ("We can skip this one, I already talked to her", .next, .next),
            ("This is not that impressive so you can archive it", .trash, nil),
            ("Don't archive it", .trash, nil),
            ("Yeah, archive all of them", .trash, nil),
            ("Go ahead and unsubscribe", .trash, nil),
        ]
        for (text, proposed, expected) in cases {
            XCTAssertEqual(LiveIntentRouter.permitted(proposed, for: text), expected, text)
        }
    }
}
