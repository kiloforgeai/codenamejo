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

    func testAReplyCarriesCopiesAnEncodedSubjectThreadingHeadersAndTheFooter() {
        let raw = MailMIME.plain(.init(to: "Dana Okafor <dana@acme.co>",
                                       cc: ["sam@acme.co", "\"Lee, Pat\" <pat@acme.co>"], bcc: ["boss@acme.co"],
                                       subject: "Re: Café — plans", body: "Works for me.",
                                       inReplyTo: "<abc@mail.gmail.com>", footer: true))
        XCTAssertEqual(raw, "VG86IERhbmEgT2thZm9yIDxkYW5hQGFjbWUuY28-DQpDYzogc2FtQGFjbWUuY28sICJMZWUsIFBhdCIgPHBhdEBhY21lLmNv"
            + "Pg0KQmNjOiBib3NzQGFjbWUuY28NClN1YmplY3Q6ID0_VVRGLTg_Qj9VbVU2SUVOaFpzT3BJT0tBbENCd2JHRnVjdz09Pz0NCkNvbnRlbnQt"
            + "VHlwZTogdGV4dC9wbGFpbjsgY2hhcnNldD1VVEYtOA0KSW4tUmVwbHktVG86IDxhYmNAbWFpbC5nbWFpbC5jb20-DQpSZWZlcmVuY2VzOiA8"
            + "YWJjQG1haWwuZ21haWwuY29tPg0KDQpXb3JrcyBmb3IgbWUuCgpTZW50IHZpYSBDb2RlbmFtZSBKbyDwn6qpIGh0dHBzOi8vY29kZW5hbWVq"
            + "by5jb20=")
        XCTAssertTrue(decoded(raw).hasSuffix("\r\n\r\nWorks for me.\n\nSent via Codename Jo 🪩 https://codenamejo.com"),
                      "the footer follows the body after a blank line")
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
