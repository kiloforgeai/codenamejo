import XCTest
@testable import CodenameJo

/// A recipient header is comma-separated and display names contain commas, so the split
/// has to know about quotes and angle brackets. Getting this wrong loses a recipient —
/// which on a send is the difference between what the assistant says it did and what
/// happened.
final class MailAddressTests: XCTestCase {

    func testNothingToParseIsAnEmptyList() {
        XCTAssertTrue(MailAddress.list(nil).isEmpty)
        XCTAssertTrue(MailAddress.list("").isEmpty)
        XCTAssertTrue(MailAddress.list("   ").isEmpty)
        XCTAssertTrue(MailAddress.list(",,").isEmpty)
    }

    func testAQuotedDisplayNameKeepsItsCommaAndStaysOneRecipient() {
        let parsed = MailAddress.list("\"Chen, Sarah\" <Sarah@Example.test>, bob@y.test")
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed.first?.name, "Chen, Sarah")
        // Bare and lowercased, because the address is the identity.
        XCTAssertEqual(parsed.first?.email, "sarah@example.test")
        XCTAssertEqual(parsed.last?.name, "")
        XCTAssertEqual(parsed.last?.email, "bob@y.test")
    }

    func testACommaInsideAngleBracketsDoesNotSplitAnEntry() {
        let parsed = MailAddress.list("Bob <b@x.test>, \"A, B\" <ab@y.test>")
        XCTAssertEqual(parsed.map(\.email), ["b@x.test", "ab@y.test"])
        XCTAssertEqual(parsed.map(\.name), ["Bob", "A, B"])
    }

    func testTheAddressIsTakenFromTheLastAngleBracketPairAndTheNameIsWhatPrecedesIt() {
        let parsed = MailAddress.list("\"Odd <thing>\" <real@x.test>")
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed.first?.email, "real@x.test")
        XCTAssertEqual(parsed.first?.name, "Odd <thing>")
    }

    func testBareAndBracketedAddressesBothParseWithNoName() {
        XCTAssertEqual(MailAddress.list("<a@b.test>").first?.email, "a@b.test")
        XCTAssertEqual(MailAddress.list("<a@b.test>").first?.name, "")
        XCTAssertEqual(MailAddress.list(" A@B.test ").first?.email, "a@b.test")
        XCTAssertEqual(MailAddress.list("\"a@b.test\"").first?.email, "a@b.test")
    }

    func testAnEntryWithNoAddressIsDroppedAndTheRestSurvive() {
        let parsed = MailAddress.list("undisclosed-recipients, c@d.test,  , e@f.test")
        XCTAssertEqual(parsed.map(\.email), ["c@d.test", "e@f.test"])
        // A display name with no address at all yields nothing rather than a blank row.
        XCTAssertTrue(MailAddress.list("Sarah Chen <>").isEmpty)
        XCTAssertTrue(MailAddress.list("Sarah Chen").isEmpty)
    }

    func testTrailingSeparatorsAndWhitespaceDoNotProduceEmptyRecipients() {
        XCTAssertEqual(MailAddress.list("a@b.test, ").map(\.email), ["a@b.test"])
        XCTAssertEqual(
            MailAddress.list("\n a@b.test ,\t c@d.test \n").map(\.email),
            ["a@b.test", "c@d.test"])
    }

    func testEveryRecipientOfALongHeaderIsReturnedInOrder() {
        let header = (1...12).map { "Person \($0) <p\($0)@x.test>" }.joined(separator: ", ")
        let parsed = MailAddress.list(header)
        XCTAssertEqual(parsed.count, 12)
        XCTAssertEqual(parsed.map(\.email), (1...12).map { "p\($0)@x.test" })
        XCTAssertEqual(parsed.first?.name, "Person 1")
    }
}
