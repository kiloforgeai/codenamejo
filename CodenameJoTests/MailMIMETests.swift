// coverage-target: CodenameJo/Services/BackgroundRefresh/MailMIME.swift

import XCTest

@testable import CodenameJo

/// The phone's raw messages against `buildRaw` in the broker's `lib/gmail.ts`. Each golden string is what that function
/// returned for the same input, so a draft or send built here is the same bytes the server sent.
final class MailMIMETests: XCTestCase {
    func testAPlainMessageIsTheServersBytesWithThePaddingKept() {
        let raw = MailMIME.plain(.init(to: "dana@acme.co", subject: "Lunch", body: "See you at noon.\nThanks"))
        XCTAssertEqual(raw, "VG86IGRhbmFAYWNtZS5jbw0KU3ViamVjdDogTHVuY2gNCkNvbnRlbnQtVHlwZTogdGV4dC9wbGFpbjsgY2hhcnNldD1VVE"
            + "YtOA0KDQpTZWUgeW91IGF0IG5vb24uClRoYW5rcw==")
        XCTAssertEqual(decoded(raw), "To: dana@acme.co\r\nSubject: Lunch\r\nContent-Type: text/plain; charset=UTF-8\r\n\r\n"
            + "See you at noon.\nThanks", "headers are CRLF-separated; the body is left as written")
    }

    func testAReplyCarriesCopiesAnEncodedSubjectThreadingHeadersAndTheFooter() throws {
        let raw = MailMIME.plain(.init(to: "Dana Okafor <dana@acme.co>",
                                       cc: ["sam@acme.co", "\"Lee, Pat\" <pat@acme.co>"], bcc: ["boss@acme.co"],
                                       subject: "Re: Café — plans", body: "Works for me.",
                                       inReplyTo: "<abc@mail.gmail.com>", footer: true))
        let mime = decoded(raw)
        XCTAssertTrue(mime.contains("Cc: sam@acme.co, \"Lee, Pat\" <pat@acme.co>\r\nBcc: boss@acme.co"))
        XCTAssertTrue(mime.contains("Subject: \(MailMIME.encodeHeader("Re: Café — plans"))\r\n"))
        XCTAssertTrue(mime.contains("In-Reply-To: <abc@mail.gmail.com>\r\nReferences: <abc@mail.gmail.com>"))
        XCTAssertTrue(mime.contains("MIME-Version: 1.0\r\nContent-Type: multipart/alternative;"))
        XCTAssertEqual(try MailMIMEParts.body(mime, type: "plain"),
                       "Works for me.\n\nSent via Codename Jo 🪩 https://codenamejo.com")
        XCTAssertTrue(try MailMIMEParts.body(mime, type: "html").contains(
            #"<a href="https://codenamejo.com">Codename Jo 🪩</a>"#))
    }

    func testLinkedSignatureEscapesTheBodyAndPreservesPlainText() throws {
        let body = "Hi <Dana> & team,\n\n  Café 🪩\n<script>alert('x')</script>"
        let mime = decoded(MailMIME.plain(.init(to: "dana@acme.co", subject: "Hello", body: body, footer: true)))
        XCTAssertEqual(try MailMIMEParts.body(mime, type: "plain"), body + "\n\n" + MailMIME.footer)
        let html = try MailMIMEParts.body(mime, type: "html")
        XCTAssertTrue(html.contains("Hi &lt;Dana&gt; &amp; team,\n\n  Café 🪩"))
        XCTAssertTrue(html.contains("&lt;script&gt;alert('x')&lt;/script&gt;"))
        XCTAssertFalse(html.contains("<script>"))
        XCTAssertTrue(html.contains("white-space: pre-wrap;"))
        XCTAssertEqual(html.components(separatedBy: #"href="https://codenamejo.com""#).count - 1, 1)
    }

    func testNoPaddingIsInventedWhenTheLengthNeedsNone() {
        XCTAssertEqual(MailMIME.plain(.init(to: "a@b.co", subject: "x", body: "ab")),
                       "VG86IGFAYi5jbw0KU3ViamVjdDogeA0KQ29udGVudC1UeXBlOiB0ZXh0L3BsYWluOyBjaGFyc2V0PVVURi04DQoNCmFi")
    }

    func testOnlyAHeaderOutsidePrintableASCIIIsEncodedAndItUsesStandardBase64() {
        XCTAssertEqual(MailMIME.encodeHeader("Plain subject (ok)"), "Plain subject (ok)")
        XCTAssertEqual(MailMIME.encodeHeader("Café"), "=?UTF-8?B?Q2Fmw6k=?=")
        XCTAssertEqual(MailMIME.encodeHeader("??>>"), "??>>")
        XCTAssertEqual(MailMIME.encodeHeader("é??>>"), "=?UTF-8?B?w6k/Pz4+?=", "RFC 2047 keeps + and /")
        XCTAssertEqual(MailMIME.base64url("??>>"), "Pz8-Pg==", "only the envelope is base64url")
    }

    private func decoded(_ raw: String) -> String {
        String(decoding: GmailAPI.decodeBase64URL(raw) ?? Data(), as: UTF8.self)
    }
}

/// Decode transfer-encoded MIME leaves independently of the production builder.
enum MailMIMEParts {
    static func body(_ mime: String, type: String) throws -> String {
        let marker = "Content-Type: text/\(type); charset=UTF-8\r\nContent-Transfer-Encoding: base64\r\n\r\n"
        let start = try XCTUnwrap(mime.range(of: marker)).upperBound
        let encoded = mime[start...].components(separatedBy: "\r\n--")[0]
        let bytes = try XCTUnwrap(Data(base64Encoded: encoded, options: .ignoreUnknownCharacters))
        return try XCTUnwrap(String(data: bytes, encoding: .utf8))
    }
}
