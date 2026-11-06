import XCTest
@testable import CodenameJo

final class LocalEmailPresentationTests: XCTestCase {
    private typealias P = LocalEmailPresentation

    private func b64(_ text: String) -> String {
        Data(text.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    }

    private func part(_ mime: String, _ text: String, filename: String? = nil) -> GmailAPI.FullPart {
        GmailAPI.FullPart(mimeType: mime, filename: filename, headers: nil,
                          body: GmailAPI.PartBody(size: text.utf8.count, data: b64(text)), parts: nil)
    }

    private func message(id: String = "m1", thread: String = "t1", parts: [GmailAPI.FullPart],
                         from: String = "Dana <dana@halden.example>", date: String = "Tue, 22 Sep 2026 10:00:00 -0700",
                         labels: [String] = ["INBOX"], snippet: String? = nil) -> GmailAPI.FullMessage {
        let headers = [("From", from), ("To", "owner@example.test"), ("Subject", "Plan"), ("Date", date)]
            .map { GmailAPI.MessageDetail.Header(name: $0.0, value: $0.1) }
        return GmailAPI.FullMessage(snippet: snippet, id: id, threadId: thread, labelIds: labels, internalDate: nil,
            payload: GmailAPI.FullPart(mimeType: "multipart/alternative", filename: nil, headers: headers, body: nil, parts: parts))
    }

    // MARK: - Envelope

    func testNestedPlainTextWinsOverHTML() {
        let envelope = P.envelope(message(parts: [part("text/html", "<p>From HTML</p>"), part("text/plain", "From plain")]),
                                  authorship: true)
        XCTAssertEqual(envelope.body, "From plain")
    }

    func testHTMLDropsHiddenAndScriptContentAndKeepsBlocks() {
        let html = "<html><head><title>T</title><style>p{color:red}</style></head><body><p>Hello&nbsp;there</p>"
            + "<div style=\"display: none\">secret <b>bold</b></div><div hidden>gone</div>"
            + "<p aria-hidden=\"true\">nope</p><script>if (a<b) {}</script>Line<br>Two &amp; more</body></html>"
        XCTAssertEqual(P.htmlToText(html), "Hello there\nLine\nTwo & more")
    }

    func testAuthorshipSplitsQuotedHistory() {
        let body = "Sounds good, Tuesday works.\n\nOn Mon, Sep 21, 2026 at 9:00 AM Ana <ana@example.test>\nwrote:\n> Can we meet?"
        let envelope = P.envelope(message(parts: [part("text/plain", body)]), authorship: true)
        XCTAssertEqual(envelope.body, "Sounds good, Tuesday works.")
        XCTAssertEqual(envelope.quotedHistory, "On Mon, Sep 21, 2026 at 9:00 AM Ana <ana@example.test>\nwrote:\n> Can we meet?")
        XCTAssertEqual(P.splitQuoted("Hi\n-----Original Message-----\nold").own, "Hi")
    }

    func testMarkupBodyFallsBackToSnippetAndAttachmentsAreNamed() {
        let css = "a{color:red;} b{margin:0;} c{padding:0;}"
        let markup = P.envelope(message(parts: [part("text/plain", css)], snippet: " Your order shipped "), authorship: true)
        XCTAssertEqual(markup.body, "Your order shipped\n\n[Message body was mostly markup; Gmail's preview follows.]")

        let file = GmailAPI.FullPart(mimeType: "application/pdf", filename: "contract.pdf", headers: nil,
                                     body: GmailAPI.PartBody(size: 2_400, data: nil, attachmentId: "a1"), parts: nil)
        let attached = P.envelope(message(parts: [part("text/plain", "See attached."), file], labels: ["SENT"]), authorship: true)
        XCTAssertEqual(attached.body, "See attached.\n\n[Attachments: contract.pdf (2 KB). Use read_attachment to read one.]")
        XCTAssertTrue(attached.fromMe)
    }

    func testOversizedSummaryIsRejectedInsteadOfClippingAwayACondition() throws {
        XCTAssertEqual(try P.spokenSummary("  Short.  "), "Short.")
        XCTAssertThrowsError(try P.spokenSummary(String(repeating: "Résumé ", count: 100)))
        XCTAssertThrowsError(try P.spokenSummary(String(repeating: "Meeting details. ", count: 16) + "Do not confirm yet."))
        XCTAssertThrowsError(try P.spokenSummary("   "))
    }

    func testPreparationRequestsOnlyASummary() async throws {
        let fetched = message(parts: [part("text/plain", "Your receipt for $12.")])
        let requests = RequestLog()
        let deps = P.Dependencies(read: { _, _ in fetched }, respond: { body, _ in
            await requests.add(body)
            return #"{"summary":"Dana sent a receipt for twelve dollars."}"#
        }, timeZone: { _ in "America/Los_Angeles" })
        let key = LiveEmailPresentation.Key(account: "owner@example.test", threadId: "t1", messageId: "m1",
                                            exchangeId: "", messageIDs: ["m1"], selectedIDs: ["m1"])
        let prepared = try await P.prepare(key, scope: .init(profileId: "p", isDefault: true), deps: deps)
        XCTAssertEqual(prepared.summary, "Dana sent a receipt for twelve dollars.")
        let bodies = await requests.bodies
        XCTAssertEqual(bodies.count, 1)
        let text = try XCTUnwrap(bodies.first?["text"] as? [String: Any])
        let format = try XCTUnwrap(text["format"] as? [String: Any])
        let schema = try XCTUnwrap(format["schema"] as? [String: Any])
        XCTAssertEqual(schema["required"] as? [String], ["summary"])
        XCTAssertEqual(Set((schema["properties"] as? [String: Any] ?? [:]).keys), ["summary"])
        XCTAssertTrue(try XCTUnwrap(prepared.speakerLine(for: #"{"done":false,"item":{"account":"owner@example.test","id":"m1","threadId":"t1"}}"#))
            .contains("What would you like to do with it?"))
    }

    func testPrepareRejectsAMessageFromAnotherThread() async throws {
        let deps = P.Dependencies(
            read: { _, _ in self.message(thread: "elsewhere", parts: [self.part("text/plain", "Hi")]) },
            respond: { _, _ in XCTFail("no summary for a rejected chain"); return "" },
            timeZone: { _ in nil })
        let key = LiveEmailPresentation.Key(account: "owner@example.test", threadId: "t1", messageId: "m1",
                                            exchangeId: "", messageIDs: ["m1"], selectedIDs: ["m1"])
        do {
            _ = try await P.prepare(key, scope: .init(profileId: "p", isDefault: true, emails: ["owner@example.test"]), deps: deps)
            XCTFail("expected a rejection")
        } catch let failure as P.Failure {
            XCTAssertEqual(failure.reason, "incomplete_email_context")
        }
    }

    func testReactionExtractionPreservesJoinedEmojiAndVisibleAltWithoutFetchingImages() {
        let html = "<p>👩🏽&zwj;💻 ❤️ 👍🏾</p><img src='https://example.test/reaction' alt='clapping hands'>"
            + "<img data-alt='fake'><img hidden alt='hidden reaction'><div style='display:none'><img alt='tracker'></div>"
        let extracted = P.envelope(message(parts: [part("text/html", html)]), authorship: true)
        XCTAssertEqual(extracted.body, "👩🏽‍💻 ❤️ 👍🏾\nclapping hands")
        XCTAssertEqual(extracted.source?.text, extracted.body)
        XCTAssertEqual(P.reactionOnly("👩🏽‍💻 ❤️ 👍🏾"), "👩🏽‍💻❤️👍🏾")
        XCTAssertEqual(P.reactionOnly("👍🏾\n\nOn Monday Dana wrote:\n> ❤️"), "👍🏾")
        XCTAssertNil(P.reactionOnly("> 👍"))
        XCTAssertNil(P.reactionOnly("Please send the report.\nDana ☀️"))
        XCTAssertNil(P.reactionOnly("123"))
        XCTAssertNil(P.reactionOnly(""))
    }

    func testReactionSourceReachesSummaryAndSpokenLineWithItsIdentity() async throws {
        let fixtures: [(String, String, String)] = [
            ("text/plain", "👍🏽", "Dana reacted with a thumbs up. The referenced message is unclear."),
            ("text/html", "<p>❤️ 👩🏽&zwj;💻</p>", "Dana replied with a heart and woman technologist emoji. The referenced message is unclear."),
            ("text/html", "<p>Dana reacted with <img alt='thumbs up' src='https://example.test/pixel'></p>", "Dana reacted with a thumbs up. The referenced message is unclear.")
        ]
        for (mime, raw, summary) in fixtures {
            let fetched = message(parts: [part(mime, raw)])
            let deps = P.Dependencies(read: { account, id in
                XCTAssertEqual(account, "owner@example.test"); XCTAssertEqual(id, "m1")
                return fetched
            }, respond: { request, _ in
                let input = try XCTUnwrap((request["input"] as? [[String: Any]])?.first?["content"] as? String)
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any])
                let source = try XCTUnwrap((json["messages"] as? [[String: Any]])?.first)
                XCTAssertEqual(source["body"] as? String, mime == "text/html" ? P.htmlToText(raw) : raw)
                XCTAssertEqual(source["id"] as? String, "m1")
                XCTAssertEqual(source["threadId"] as? String, "t1")
                XCTAssertEqual(source["reactionOnly"] as? String, P.reactionOnly(mime == "text/html" ? P.htmlToText(raw) : raw))
                let instructions = try XCTUnwrap(request["instructions"] as? String)
                XCTAssertTrue(instructions.contains("name the actual reaction in spoken words"))
                XCTAssertTrue(instructions.contains("Quoted emoji belong to the quoted author"))
                return String(decoding: try JSONSerialization.data(withJSONObject: ["summary": summary]), as: UTF8.self)
            }, timeZone: { _ in nil })
            let key = LiveEmailPresentation.Key(account: "owner@example.test", threadId: "t1", messageId: "m1",
                exchangeId: "", messageIDs: ["m1"], selectedIDs: ["m1"])
            let prepared = try await P.prepare(key, scope: .init(profileId: "p", isDefault: true), deps: deps)
            let step = #"{"done":false,"item":{"account":"owner@example.test","id":"m1","threadId":"t1"}}"#
            XCTAssertTrue(try XCTUnwrap(prepared.speakerLine(for: step)).contains(summary))
            XCTAssertNil(prepared.speakerLine(for: step.replacingOccurrences(of: "m1", with: "m2")))
            XCTAssertEqual(prepared.emailContent?.messages.first?.text, mime == "text/html" ? P.htmlToText(raw) : raw)
        }
    }
}

private actor RequestLog {
    var bodies: [[String: Any]] = []
    func add(_ body: [String: Any]) { bodies.append(body) }
}
