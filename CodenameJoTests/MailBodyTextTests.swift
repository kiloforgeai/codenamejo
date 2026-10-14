import XCTest
@testable import CodenameJo

/// Reducing a Gmail MIME tree to the words someone typed. Everything downstream — the
/// summary the assistant speaks, the writing-tone samples — reads what this returns, so a
/// tree it walks wrongly is a message the user hears wrongly.
final class MailBodyTextTests: XCTestCase {

    private func base64URL(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func leaf(_ mime: String, _ text: String, filename: String = "") -> GmailAPI.FullPart {
        GmailAPI.FullPart(
            mimeType: mime, filename: filename, headers: nil,
            body: GmailAPI.PartBody(size: text.utf8.count, data: base64URL(text)), parts: nil)
    }

    private func branch(_ mime: String, _ children: [GmailAPI.FullPart]) -> GmailAPI.FullPart {
        GmailAPI.FullPart(mimeType: mime, filename: "", headers: nil, body: nil, parts: children)
    }

    func testNoPartIsNoText() {
        XCTAssertEqual(MailBodyText.plainText(nil), "")
    }

    func testASinglePlainLeafIsTheBody() {
        XCTAssertEqual(MailBodyText.plainText(leaf("text/plain", "Thursday works.")), "Thursday works.")
    }

    /// `multipart/alternative` carries the same message twice. The typed version wins; the
    /// HTML copy must not be appended to it.
    func testThePlainAlternativeWinsOverTheHTMLCopy() {
        let tree = branch("multipart/alternative", [
            leaf("text/plain", "Thursday works."),
            leaf("text/html", "<p>Thursday works.</p>"),
        ])
        XCTAssertEqual(MailBodyText.plainText(tree), "Thursday works.")
    }

    func testHTMLIsOnlyUsedWhenThereIsNoPlainPart() {
        let tree = branch("multipart/alternative", [leaf("text/html", "<p>Hi<br>there</p>")])
        XCTAssertEqual(MailBodyText.plainText(tree), "Hi\nthere\n")
    }

    func testNestedPartsAreCollectedInOrderAcrossTheWholeTree() {
        let tree = branch("multipart/mixed", [
            leaf("text/plain", "First."),
            branch("multipart/related", [leaf("TEXT/PLAIN; charset=UTF-8", "Second.")]),
        ])
        XCTAssertEqual(MailBodyText.plainText(tree), "First.\nSecond.")
    }

    /// An attachment carries a filename, and its text is not the message — a .txt attachment
    /// read as the body would be spoken as if the sender had written it.
    func testAttachmentsAndImagesAreSkipped() {
        let tree = branch("multipart/mixed", [
            leaf("text/plain", "See attached."),
            leaf("text/plain", "column,value", filename: "report.csv"),
            leaf("image/png", "not really a png"),
        ])
        XCTAssertEqual(MailBodyText.plainText(tree), "See attached.")
    }

    /// A body Gmail did not inline has no `data`, and one that will not decode is not text.
    /// Neither may take the whole message down with it.
    func testAPartThatCannotBeDecodedContributesNothing() {
        let undecodable = GmailAPI.FullPart(
            mimeType: "text/plain", filename: "", headers: nil,
            body: GmailAPI.PartBody(size: 10, data: "not base64!!"), parts: nil)
        let missing = GmailAPI.FullPart(
            mimeType: "text/plain", filename: "", headers: nil, body: nil, parts: nil)

        XCTAssertEqual(MailBodyText.plainText(undecodable), "")
        XCTAssertEqual(MailBodyText.plainText(missing), "")
        XCTAssertEqual(
            MailBodyText.plainText(branch("multipart/mixed", [undecodable, leaf("text/plain", "Kept.")])),
            "Kept.")
    }

    func testBase64URLDecodesWithoutPaddingAndInTheURLSafeAlphabet() {
        XCTAssertEqual(MailBodyText.decodeBase64URL("SGVsbG8sIHdvcmxkIQ"), "Hello, world!")
        XCTAssertEqual(MailBodyText.decodeBase64URL("SGVsbG8sIHdvcmxkIQ=="), "Hello, world!")
        // `-` and `_` stand in for `+` and `/`, which appear in any body with an emoji in it.
        XCTAssertEqual(MailBodyText.decodeBase64URL("8J-Ygg"), "😂")
        XCTAssertNil(MailBodyText.decodeBase64URL("not base64!!"))
    }

    func testStrippingHTMLDropsScriptAndStyleBlocksEntirely() {
        let html = "<style>p { color: red; }</style><p>Hello</p><script>alert('x');</script>Bye"
        XCTAssertEqual(MailBodyText.stripHTML(html), "Hello\nBye")
    }

    func testStrippingHTMLTurnsBlockEndsIntoLineBreaksAndDecodesEntities() {
        XCTAssertEqual(
            MailBodyText.stripHTML("<div>Tom &amp; Jerry</div><div>&lt;draft&gt;&nbsp;ok</div>"),
            "Tom & Jerry\n<draft> ok\n")
    }
}
