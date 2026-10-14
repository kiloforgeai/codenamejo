import XCTest
@testable import CodenameJo

final class LiveIntentRouterTests: XCTestCase {
    func testWordsMustNameTheAction() {
        let cases: [(String, LiveFastAction, LiveFastAction?)] = [
            ("Yeah, go ahead", .trash, nil),
            ("Same thing here as well", .archive, nil),
            ("Yeah, that's correct", .archive, nil),
            ("garbage", .spam, nil),
            ("this", .archive, nil),
            ("Yeah, just get rid of this", .trash, .archive),
            ("Toss it", .trash, .archive),
            ("Just delete it, please", .trash, .trash),
            ("This is junk", .spam, .spam),
            ("Let's move along", .next, .next),
            ("We can skip this one, I already talked to her", .next, .next),
            ("This is not that impressive so you can archive it", .archive, .archive),
            ("Don't archive it", .archive, nil),
            ("Yeah, archive all of them", .archive, nil),
            ("Go ahead and unsubscribe", .archive, nil),
        ]
        for (text, proposed, expected) in cases {
            XCTAssertEqual(LiveIntentRouter.permitted(proposed, for: text), expected, text)
        }
    }
}
