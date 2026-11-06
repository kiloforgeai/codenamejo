import XCTest
@testable import CodenameJo

final class EmailPreviewTests: XCTestCase {
    func testDecodesOnceWithoutInterpretingMarkup() {
        let preview = EmailPreview(snippet: "A &lt;a@example.test&gt; &amp; B &#128075; &#x1F600; &amp;lt;script&amp;gt;")
        XCTAssertEqual(preview.text, "A <a@example.test> & B 👋 😀 &lt;script&gt;")
        XCTAssertEqual(EmailPreview(snippet: "<img src='https://example.test/pixel'>").text,
                       "<img src='https://example.test/pixel'>")
        XCTAssertEqual(EmailPreview(snippet: "literal &unknown; &#x110000; & unfinished").text,
                       "literal &unknown; &#x110000; & unfinished")
    }

    func testPreservesParagraphsAndSeparatesExplicitQuotes() {
        let preview = EmailPreview(snippet: "Thanks!\r\n\r\nI will be there.\r\n\r\n&gt; Can you attend?\r\n&gt;&gt; Earlier question")
        XCTAssertEqual(preview.text, "Thanks!\n\nI will be there.")
        XCTAssertTrue(preview.quoted.contains("> Can you attend?"))
        XCTAssertTrue(preview.quoted.contains(">> Earlier question"))
    }

    func testOpenMessageIsPinnedToAccountAndID() throws {
        let url = try XCTUnwrap(EmailPreview.gmailURL(account: "qa+test@example.test", messageID: "abc123"))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.host, "mail.google.com")
        XCTAssertEqual(components.queryItems?.first?.value, "qa+test@example.test")
        XCTAssertEqual(components.fragment, "all/abc123")
        XCTAssertNil(EmailPreview.gmailURL(account: "qa@example.test", messageID: nil))
    }
}
