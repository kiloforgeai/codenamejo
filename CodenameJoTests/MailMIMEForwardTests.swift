// coverage-target: CodenameJo/Services/BackgroundRefresh/MailMIME.swift

import Foundation
import XCTest

@testable import CodenameJo

/// The phone's forwards against `buildForwardRaw` in the broker's `lib/gmail.ts`. Each golden string is what that
/// function returned for the same input with the boundaries fixed, so a forward built here is the server's bytes.
final class MailMIMEForwardTests: XCTestCase {
    private let source = MailMIME.ForwardSource(
        from: "Dana Okafor <dana@acme.test>", date: "Tue, 25 Aug 2026 09:00:00 -0700",
        subject: "Re: Fwd: Q3 <numbers> & plan", to: "you@kiloforge.test", rfcMessageId: "<orig@mail.test>",
        threadId: "t1", text: "Numbers attached.\nThanks")

    /// The broker's `b_<uuid>`, numbered in the order the builder asks for them.
    private func boundaries() -> () -> String {
        var next = 0
        return {
            defer { next += 1 }
            return "b_00000000-0000-0000-0000-00000000000\(next)"
        }
    }

    private func decoded(_ raw: String) -> String {
        String(decoding: GmailAPI.decodeBase64URL(raw) ?? Data(), as: UTF8.self)
    }

    func testAPlainOriginalIsOneTextPartUnderAFwdSubjectThreadedOnTheOriginal() {
        let raw = MailMIME.forward(.init(to: "sam@acme.test", source: source), boundary: boundaries())
        XCTAssertEqual(raw, "VG86IHNhbUBhY21lLnRlc3QNClN1YmplY3Q6IEZ3ZDogUTMgPG51bWJlcnM-ICYgcGxhbg0KTUlNRS1WZXJzaW9uOiAxLjANCkluLVJlcGx5LV"
            + "RvOiA8b3JpZ0BtYWlsLnRlc3Q-DQpSZWZlcmVuY2VzOiA8b3JpZ0BtYWlsLnRlc3Q-DQpDb250ZW50LVR5cGU6IHRleHQvcGxhaW47IGNoYXJz"
            + "ZXQ9VVRGLTgNCkNvbnRlbnQtVHJhbnNmZXItRW5jb2Rpbmc6IGJhc2U2NA0KDQpMUzB0TFMwdExTMHRMU0JHYjNKM1lYSmtaV1FnYldWemMyRm"
            + "5aU0F0TFMwdExTMHRMUzBLUm5KdmJUb2dSR0Z1WVNCUGEyRm1iM0lnDQpQR1JoYm1GQVlXTnRaUzUwWlhOMFBncEVZWFJsT2lCVWRXVXNJREkx"
            + "SUVGMVp5QXlNREkySURBNU9qQXdPakF3SUMwd056QXdDbE4xDQpZbXBsWTNRNklGSmxPaUJHZDJRNklGRXpJRHh1ZFcxaVpYSnpQaUFtSUhCc1"
            + "lXNEtWRzg2SUhsdmRVQnJhV3h2Wm05eVoyVXVkR1Z6DQpkQW9LVG5WdFltVnljeUJoZEhSaFkyaGxaQzRLVkdoaGJtdHo=")
        let text = decoded(raw)
        XCTAssertTrue(text.contains("Subject: Fwd: Q3 <numbers> & plan\r\n"), "every leading Re:/Fwd: comes off, then one Fwd:")
        XCTAssertTrue(text.contains("In-Reply-To: <orig@mail.test>\r\nReferences: <orig@mail.test>\r\n"))
        XCTAssertFalse(text.contains("multipart/"), "no HTML and nothing attached: no wrapper")
    }

    func testAnHTMLOriginalGetsBothPartsWithTheNoteTheCcRowAndTheFooter() throws {
        var html = source
        html.cc = "Pat <pat@acme.test>"
        html.html = "<p>Numbers <b>attached</b></p>"
        html.subject = ""
        let raw = MailMIME.forward(.init(to: "sam@acme.test", cc: ["lee@acme.test"], note: "  Please review.  ", source: html,
                                         footer: true), boundary: boundaries())
        let text = try MailMIMEParts.body(decoded(raw), type: "plain")
        let body = try MailMIMEParts.body(decoded(raw), type: "html")
        XCTAssertTrue(text.hasSuffix("Sent via Codename Jo 🪩 https://codenamejo.com"))
        XCTAssertTrue(body.contains(html.html), "Original HTML is preserved")
        XCTAssertTrue(body.contains("Please review."))
        XCTAssertTrue(body.contains("Cc: Pat &lt;pat@acme.test&gt;"))
        XCTAssertTrue(body.contains(#"<a href="https://codenamejo.com">Codename Jo 🪩</a>"#))
        XCTAssertTrue(decoded(raw).contains("Subject: Fwd: (no subject)\r\n"))
    }

    func testPlainForwardWithSignatureGetsALinkAndKeepsAttachments() throws {
        var original = source
        original.text = "Hi <Dana> & team\n\n  Numbers attached."
        let bytes = Data([0, 1, 2, 128, 255])
        let attachment = MailMIME.Attachment(filename: "numbers.pdf", mimeType: "application/pdf", size: 5, attachmentId: "a1")
        let mime = decoded(MailMIME.forward(.init(to: "sam@acme.test", source: original,
            attachments: [(attachment, bytes)], footer: true), boundary: boundaries()))
        XCTAssertTrue(mime.contains("Content-Type: multipart/mixed;"))
        XCTAssertTrue(mime.contains("Content-Type: multipart/alternative;"))
        XCTAssertTrue(mime.contains("AAECgP8="), "Attachment bytes are unchanged")
        XCTAssertTrue(try MailMIMEParts.body(mime, type: "plain").contains(original.text))
        let html = try MailMIMEParts.body(mime, type: "html")
        XCTAssertTrue(html.contains("Hi &lt;Dana&gt; &amp; team\n\n  Numbers attached."))
        XCTAssertTrue(html.contains(#"<a href="https://codenamejo.com">Codename Jo 🪩</a>"#))
    }

    func testHTMLForwardWithSignatureOffAddsNoJoLink() throws {
        var original = source
        original.html = "<p>Original body</p>"
        let mime = decoded(MailMIME.forward(.init(to: "sam@acme.test", source: original), boundary: boundaries()))
        XCTAssertFalse(try MailMIMEParts.body(mime, type: "html").contains("codenamejo.com"))
        XCTAssertFalse(try MailMIMEParts.body(mime, type: "plain").contains("codenamejo.com"))
    }

    func testAttachmentsRideInAMixedWrapperWithInlineImagesKeepingTheirContentID() {
        var withImage = source
        withImage.rfcMessageId = ""
        withImage.html = "<img src=\"cid:logo\">"
        let attachments: [(ref: MailMIME.Attachment, bytes: Data)] = [
            (.init(filename: "Q3 \"final\".pdf", mimeType: "application/pdf", size: 5, attachmentId: "a1"),
             Data([0, 1, 2, 128, 255])),
            (.init(filename: "logo.png", mimeType: "image/png", size: 3, attachmentId: "", contentId: "<logo>"), Data("png".utf8)),
            (.init(filename: "Résumé.txt", mimeType: "text/plain", size: 100, attachmentId: "a3"), Data(repeating: 65, count: 100)),
        ]
        let raw = MailMIME.forward(.init(to: "sam@acme.test", source: withImage, attachments: attachments),
                                   boundary: boundaries())
        XCTAssertEqual(raw, "VG86IHNhbUBhY21lLnRlc3QNClN1YmplY3Q6IEZ3ZDogUTMgPG51bWJlcnM-ICYgcGxhbg0KTUlNRS1WZXJzaW9uOiAxLjANCkNvbnRlbnQtVH"
            + "lwZTogbXVsdGlwYXJ0L21peGVkOyBib3VuZGFyeT0iYl8wMDAwMDAwMC0wMDAwLTAwMDAtMDAwMC0wMDAwMDAwMDAwMDEiDQoNCi0tYl8wMDAw"
            + "MDAwMC0wMDAwLTAwMDAtMDAwMC0wMDAwMDAwMDAwMDENCkNvbnRlbnQtVHlwZTogbXVsdGlwYXJ0L2FsdGVybmF0aXZlOyBib3VuZGFyeT0iYl"
            + "8wMDAwMDAwMC0wMDAwLTAwMDAtMDAwMC0wMDAwMDAwMDAwMDAiDQoNCi0tYl8wMDAwMDAwMC0wMDAwLTAwMDAtMDAwMC0wMDAwMDAwMDAwMDAN"
            + "CkNvbnRlbnQtVHlwZTogdGV4dC9wbGFpbjsgY2hhcnNldD1VVEYtOA0KQ29udGVudC1UcmFuc2Zlci1FbmNvZGluZzogYmFzZTY0DQoNCkxTMH"
            + "RMUzB0TFMwdExTQkdiM0ozWVhKa1pXUWdiV1Z6YzJGblpTQXRMUzB0TFMwdExTMEtSbkp2YlRvZ1JHRnVZU0JQYTJGbWIzSWcNClBHUmhibUZB"
            + "WVdOdFpTNTBaWE4wUGdwRVlYUmxPaUJVZFdVc0lESTFJRUYxWnlBeU1ESTJJREE1T2pBd09qQXdJQzB3TnpBd0NsTjENClltcGxZM1E2SUZKbE"
            + "9pQkdkMlE2SUZFeklEeHVkVzFpWlhKelBpQW1JSEJzWVc0S1ZHODZJSGx2ZFVCcmFXeHZabTl5WjJVdWRHVnoNCmRBb0tUblZ0WW1WeWN5Qmhk"
            + "SFJoWTJobFpDNEtWR2hoYm10eg0KLS1iXzAwMDAwMDAwLTAwMDAtMDAwMC0wMDAwLTAwMDAwMDAwMDAwMA0KQ29udGVudC1UeXBlOiB0ZXh0L2"
            + "h0bWw7IGNoYXJzZXQ9VVRGLTgNCkNvbnRlbnQtVHJhbnNmZXItRW5jb2Rpbmc6IGJhc2U2NA0KDQpQSEErTFMwdExTMHRMUzB0TFNCR2IzSjNZ"
            + "WEprWldRZ2JXVnpjMkZuWlNBdExTMHRMUzB0TFMwOFluSStDa1p5YjIwNklFUmhibUVnDQpUMnRoWm05eUlDWnNkRHRrWVc1aFFHRmpiV1V1ZE"
            + "dWemRDWm5kRHM4WW5JK0NrUmhkR1U2SUZSMVpTd2dNalVnUVhWbklESXdNallnDQpNRGs2TURBNk1EQWdMVEEzTURBOFluSStDbE4xWW1wbFkz"
            + "UTZJRkpsT2lCR2QyUTZJRkV6SUNac2REdHVkVzFpWlhKekptZDBPeUFtDQpZVzF3T3lCd2JHRnVQR0p5UGdwVWJ6b2dlVzkxUUd0cGJHOW1iM0"
            + "puWlM1MFpYTjBQQzl3UGdvOGFXMW5JSE55WXowaVkybGtPbXh2DQpaMjhpUGc9PQ0KLS1iXzAwMDAwMDAwLTAwMDAtMDAwMC0wMDAwLTAwMDAw"
            + "MDAwMDAwMC0tDQotLWJfMDAwMDAwMDAtMDAwMC0wMDAwLTAwMDAtMDAwMDAwMDAwMDAxDQpDb250ZW50LVR5cGU6IGFwcGxpY2F0aW9uL3BkZj"
            + "sgbmFtZT0iUTMgXCJmaW5hbFwiLnBkZiINCkNvbnRlbnQtRGlzcG9zaXRpb246IGF0dGFjaG1lbnQ7IGZpbGVuYW1lPSJRMyBcImZpbmFsXCIu"
            + "cGRmIg0KQ29udGVudC1UcmFuc2Zlci1FbmNvZGluZzogYmFzZTY0DQoNCkFBRUNnUDg9DQotLWJfMDAwMDAwMDAtMDAwMC0wMDAwLTAwMDAtMD"
            + "AwMDAwMDAwMDAxDQpDb250ZW50LVR5cGU6IGltYWdlL3BuZzsgbmFtZT0ibG9nby5wbmciDQpDb250ZW50LURpc3Bvc2l0aW9uOiBpbmxpbmU7"
            + "IGZpbGVuYW1lPSJsb2dvLnBuZyINCkNvbnRlbnQtVHJhbnNmZXItRW5jb2Rpbmc6IGJhc2U2NA0KQ29udGVudC1JRDogPGxvZ28-DQoNCmNHNW"
            + "4NCi0tYl8wMDAwMDAwMC0wMDAwLTAwMDAtMDAwMC0wMDAwMDAwMDAwMDENCkNvbnRlbnQtVHlwZTogdGV4dC9wbGFpbjsgbmFtZT0iPT9VVEYt"
            + "OD9CP1VzT3BjM1Z0dzZrdWRIaDA_PSINCkNvbnRlbnQtRGlzcG9zaXRpb246IGF0dGFjaG1lbnQ7IGZpbGVuYW1lPSI9P1VURi04P0I_VXNPcG"
            + "MzVnR3Nmt1ZEhoMD89Ig0KQ29udGVudC1UcmFuc2Zlci1FbmNvZGluZzogYmFzZTY0DQoNClFVRkJRVUZCUVVGQlFVRkJRVUZCUVVGQlFVRkJR"
            + "VUZCUVVGQlFVRkJRVUZCUVVGQlFVRkJRVUZCUVVGQlFVRkJRVUZCUVVGQlFVRkINClFVRkJRVUZCUVVGQlFVRkJRVUZCUVVGQlFVRkJRVUZCUV"
            + "VGQlFVRkJRVUZCUVVGQlFVRkJRVUZCUVE9PQ0KLS1iXzAwMDAwMDAwLTAwMDAtMDAwMC0wMDAwLTAwMDAwMDAwMDAwMS0t")
        let text = decoded(raw)
        XCTAssertTrue(text.contains("Content-Disposition: inline; filename=\"logo.png\"\r\nContent-Transfer-Encoding: base64\r\n"
            + "Content-ID: <logo>"))
        XCTAssertTrue(text.contains("filename=\"Q3 \\\"final\\\".pdf\""), "quotes in an ASCII name are backslash-escaped")
        XCTAssertTrue(text.contains("name=\"=?UTF-8?B?UsOpc3Vtw6kudHh0?=\""), "a non-ASCII name is an RFC 2047 word")
        XCTAssertFalse(text.contains("In-Reply-To"), "no Message-ID on the original, no threading headers")
    }

    func testPartBodiesFoldAtSeventySixColumns() {
        let folded = MailMIME.base64Lines(Data(repeating: 65, count: 100))
        XCTAssertEqual(folded.components(separatedBy: "\r\n").map(\.count), [76, 60])
        XCTAssertEqual(MailMIME.base64Lines(Data(repeating: 65, count: 57)), String(repeating: "QUFB", count: 19) + "\r\n",
                       "an exact multiple of 76 still ends with the fold, as the server's regex leaves it")
    }
}
