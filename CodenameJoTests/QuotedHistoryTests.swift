import XCTest
@testable import CodenameJo

/// Cutting the quoted history off a reply so what is left is only what the user wrote.
/// Cutting too late feeds the other side's words back in as the user's own; cutting too
/// early throws away the reply itself.
final class QuotedHistoryTests: XCTestCase {

    func testGmailsAttributionLineEndsTheReply() {
        let body = """
            Yes, Thursday works.

            On Mon, 3 Mar 2026, Alice <alice@example.test> wrote:
            > Can we move it?
            """
        XCTAssertEqual(QuotedHistory.strip(body), "Yes, Thursday works.")
    }

    /// The attribution wraps when the display name is long, leaving "wrote:" on its own
    /// line — the whole header still has to go.
    func testAWrappedAttributionLineIsStillTheBoundary() {
        let body = """
            Reply body.
            On Mon, 3 Mar 2026 at 09:00, Alice Example <alice@example.test>
            wrote:
            > Can we move it?
            """
        XCTAssertEqual(QuotedHistory.strip(body), "Reply body.")
    }

    func testOutlookAndForwardedHeadersEndTheReplyToo() {
        XCTAssertEqual(
            QuotedHistory.strip("Thanks.\n\n-----Original Message-----\nFrom: bob@example.test"),
            "Thanks.")
        XCTAssertEqual(
            QuotedHistory.strip("Thanks.\n_______\nFrom: bob@example.test"),
            "Thanks.")
        XCTAssertEqual(
            QuotedHistory.strip("Thanks.\nFrom: bob@example.test\nSubject: Re: hello"),
            "Thanks.")
    }

    func testTheSignatureSeparatorAndOurOwnFooterEndTheReply() {
        XCTAssertEqual(QuotedHistory.strip("See you then.\n--\nAlex\nFounder"), "See you then.")
        XCTAssertEqual(
            QuotedHistory.strip("See you then.\nSent via Codename Jo 🪩 https://codenamejo.com"),
            "See you then.")
    }

    func testQuotedLinesAboveTheCutAreDroppedAsWell() {
        XCTAssertEqual(QuotedHistory.strip("> Can we move it?\nYes, Thursday works."),
                       "Yes, Thursday works.")
    }

    /// A sentence that merely starts with "On", a name that is not an address, and a single
    /// dash are not boundaries. Treating them as one silently truncates the reply.
    func testProseThatLooksLikeAMarkerIsNotOne() {
        let opensWithOn = "On the whole this works.\nLet's do Thursday."
        XCTAssertEqual(QuotedHistory.strip(opensWithOn), opensWithOn)

        let noAddress = "Thanks.\nFrom: Alice in accounts"
        XCTAssertEqual(QuotedHistory.strip(noAddress), noAddress)

        let singleDash = "Thanks.\n-\nAlex"
        XCTAssertEqual(QuotedHistory.strip(singleDash), singleDash)
    }

    func testCarriageReturnsDoNotHideTheBoundary() {
        let body = "Reply body.\r\n\r\nOn Mon, Alice <alice@example.test> wrote:\r\n> Can we move it?"
        XCTAssertEqual(QuotedHistory.strip(body), "Reply body.")
    }

    func testABodyWithNoHistoryKeepsItsShapeWithRunsOfBlankLinesCollapsed() {
        XCTAssertEqual(QuotedHistory.strip("\nLine one.\n\n\n\nLine two.\n\n"),
                       "Line one.\n\nLine two.")
        XCTAssertEqual(QuotedHistory.strip(""), "")
        XCTAssertEqual(QuotedHistory.strip("   \n  "), "")
    }

    /// Nothing but quoted history is an empty reply, not the quote.
    func testAReplyThatIsOnlyQuotedHistoryComesBackEmpty() {
        XCTAssertEqual(QuotedHistory.strip("On Mon, Alice wrote:\n> Can we move it?"), "")
        XCTAssertEqual(QuotedHistory.strip("> Can we move it?\n> Please."), "")
    }
}
