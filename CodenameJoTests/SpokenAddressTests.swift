import XCTest
@testable import CodenameJo

/// Jo's transcript is what the screen and History show, so a spoken address must read as written.
final class SpokenAddressTests: XCTestCase {

    func testTheReportedTranscriptReadsAsAnAddress() {
        XCTAssertEqual(
            SpokenAddress.written("your reply is drafted to jamie at examplepartners dot com asking if he got your sign-up"),
            "your reply is drafted to jamie@examplepartners.com asking if he got your sign-up")
    }

    func testAHalfWrittenAddressIsFinished() {
        XCTAssertEqual(SpokenAddress.written("It's maya@example dot com."), "It's maya@example.com.")
        XCTAssertEqual(SpokenAddress.written("It's maya@kiloforge dot test"), "It's maya@kiloforge.test")
    }

    func testSpelledLocalPartsAndMultiPartDomains() {
        XCTAssertEqual(SpokenAddress.written("rob dot smith at mail dot corp dot co dot uk"), "rob.smith@mail.corp.co.uk")
        XCTAssertEqual(SpokenAddress.written("Rob at Example DOT com"), "Rob@example.com")
    }

    func testAChainOfAddressesIsRewrittenWhole() {
        XCTAssertEqual(
            SpokenAddress.written("Sent to rob at acme dot com and maya at example dot com, or lee at x dot io."),
            "Sent to rob@acme.com and maya@example.com, or lee@x.io.")
    }

    func testAnAddressThatLooksLikeAWordStillConverts() {
        XCTAssertEqual(SpokenAddress.written("reply to info at acme dot com"), "reply to info@acme.com")
        XCTAssertEqual(SpokenAddress.written("Peter's email is peter at acme dot com"), "Peter's email is peter@acme.com")
        XCTAssertEqual(SpokenAddress.written("Ted's address is ted at acme dot com"), "Ted's address is ted@acme.com")
    }

    func testACueBeforeAQuestionMarkStillCounts() {
        XCTAssertEqual(SpokenAddress.written("His address? jamie at example dot com"), "His address? jamie@example.com")
    }

    func testTheEvalTranscriptsReadAsAddresses() {
        XCTAssertEqual(SpokenAddress.written("It’s maya at kiloforge dot test."), "It’s maya@kiloforge.test.")
        XCTAssertEqual(SpokenAddress.written("maya at kiloforge dot test."), "maya@kiloforge.test.")
        XCTAssertEqual(SpokenAddress.written("Maya's email is maya at example dot com."), "Maya's email is maya@example.com.")
    }

    func testAWrittenAddressIsLeftAlone() {
        let text = "Sent to rob@example.com and maya@kiloforge.test."
        XCTAssertEqual(SpokenAddress.written(text), text)
    }

    func testProseWithAtIsLeftAlone() {
        for text in ["I'll be at lunch", "meet at 3", "the team at Stripe", "look at kiloforge dot com",
                     "I'm at kiloforge dot com", "Mark it as read at noon.", "sign up at kiloforge.com", "You can sign up at kiloforge dot com",
                     "More details at example dot com.", "The office is here at kiloforge dot com",
                     "It's live at kiloforge dot com", "The site is up at kiloforge dot com",
                     "It's hosted at kiloforge dot com", "It's open to everyone at kiloforge dot com",
                     "It's launching at kiloforge dot com", "The form is ready at kiloforge dot com",
                     "It's published at blog dot kiloforge dot com", "It's cheaper at amazon dot com",
                     "an email from Stripe at stripe dot com"] {
            XCTAssertEqual(SpokenAddress.written(text), text, text)
        }
    }

    func testAStreamingPrefixIsNotRewrittenEarly() {
        XCTAssertEqual(SpokenAddress.written("drafted to jamie at examplepartners"), "drafted to jamie at examplepartners")
        XCTAssertEqual(SpokenAddress.written("drafted to jamie at examplepartners dot"), "drafted to jamie at examplepartners dot")
    }
}
