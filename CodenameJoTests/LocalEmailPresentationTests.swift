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

    // MARK: - Spoken parts

    func testArchiveWordingAndSenderCountRule() async {
        func content(_ scope: String?, _ question: String? = nil) -> P.Content {
            P.Content(summary: "s", suggestedQuestion: question, archiveScope: scope)
        }
        let two: @Sendable (String, String, Int) async throws -> Int = { _, query, cap in
            XCTAssertEqual(query, "in:inbox from:receipts@shop.example")
            XCTAssertEqual(cap, 2)
            return 2
        }
        let one: @Sendable (String, String, Int) async throws -> Int = { _, _, _ in 1 }
        let from = "\"Shop Receipts\" <receipts@shop.example>"
        let sender = await P.resolveArchiveSuggestion(content("sender"), account: "a@x.test", from: from, fromMe: false, count: two)
        XCTAssertEqual(sender, "Want me to archive all your Shop Receipts emails?")
        let lone = await P.resolveArchiveSuggestion(content("sender"), account: "a@x.test", from: from, fromMe: false, count: one)
        XCTAssertEqual(lone, P.singleArchive)
        let mine = await P.resolveArchiveSuggestion(content("sender"), account: "a@x.test", from: from, fromMe: true, count: two)
        XCTAssertEqual(mine, P.singleArchive)
        let message = await P.resolveArchiveSuggestion(content("message"), account: "a@x.test", from: from, fromMe: false, count: two)
        XCTAssertEqual(message, P.singleArchive)
        let other = await P.resolveArchiveSuggestion(content(nil, "Want me to find a time?"), account: "a@x.test",
                                                     from: from, fromMe: false, count: two)
        XCTAssertEqual(other, "Want me to find a time?")
    }

    func testSummaryTrimsToFitAndEndsOnTheReason() throws {
        let long = Array(repeating: "word", count: 80).joined(separator: " ")
        let withReason = try P.spokenSummary(long, question: "Want me to reply?", reason: " It's a part-time role. ")
        XCTAssertTrue(withReason.hasSuffix(" It's a part-time role."))
        XCTAssertLessThanOrEqual(withReason.utf8.count, 210)
        let check = try P.spokenSummary("Short.", question: "Want me to check where they're based?", reason: "No city.")
        XCTAssertEqual(check, "Short.")
        XCTAssertLessThanOrEqual(try P.spokenSummary(long, question: nil, reason: "x").utf8.count, 250)
        XCTAssertEqual(P.trimToBytes("one two three", 7), "one two")
        XCTAssertThrowsError(try P.spokenSummary("   ", question: nil, reason: nil))
    }

    // MARK: - Categories

    func testChooseCategory() {
        let known = [P.Category(name: "receipt", description: "Purchase receipts")]
        XCTAssertEqual(P.chooseCategory(known, decision: .init(choice: "receipt", confidence: 0.9), guess: nil)?.category.name, "receipt")
        let guessed = P.chooseCategory(known, decision: .init(choice: "receipt", confidence: 0.3),
                                       guess: .init(name: "Cold Sales Outreach", description: " Unsolicited pitches "))
        XCTAssertEqual(guessed?.category, P.Category(name: "cold_sales_outreach", description: "Unsolicited pitches"))
        XCTAssertEqual(guessed?.isNew, true)
        XCTAssertEqual(P.chooseCategory(known, decision: nil, guess: .init(name: "Receipt", description: "x"))?.isNew, false)
        XCTAssertNil(P.chooseCategory(known, decision: nil, guess: .init(name: "none of these", description: "x")))
        XCTAssertEqual(P.parseDecision(["answers": [["name": "category", "choice": "receipt", "confidence": 0.7]] as [[String: Any]]]),
                       P.Decision(choice: "receipt", confidence: 0.7))
    }

    func testPlaybookParsingKeepsWholeSentencesUnderTheCap() throws {
        XCTAssertNil(P.parsePlaybook(#"{"playbook":"They archive.","changed":false}"#))
        XCTAssertEqual(P.parsePlaybook(#"{"playbook":"  They   archive. ","changed":true}"#), "They archive.")
        let sentence = "They reply when the candidate is full-time and otherwise they archive it. "
        let long = String(repeating: sentence, count: 12)
        let raw = String(decoding: try JSONSerialization.data(withJSONObject: ["playbook": long, "changed": true]), as: UTF8.self)
        let kept = try XCTUnwrap(P.parsePlaybook(raw))
        XCTAssertLessThanOrEqual(kept.utf8.count, P.playbookBytes)
        XCTAssertTrue(kept.hasSuffix("archive it."))
        let turns = P.parseTurns([("assistant", "Hi"), ("user", "  archive it  "), ("system", "x")])
        XCTAssertEqual(turns?.map(\.text), ["Hi", "archive it"])
        XCTAssertNil(P.parseTurns([("assistant", "Hi")]))
    }

    // MARK: - Store and the whole preparation

    private func store() throws -> EmailCategoryRows {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return EmailCategoryRows(dbPool: try XCTUnwrap(LocalContextStore(url: url).dbPool))
    }

    func testStoreCapsOrdersAndScopesByUser() throws {
        let rows = try store()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for index in 0..<22 {
            try rows.touch(userId: "u1", account: "A@x.test", name: "c\(index)", description: "d",
                           now: start.addingTimeInterval(Double(index)))
        }
        try rows.touch(userId: "u2", account: "a@x.test", name: "other", description: "d", now: start)
        let known = try rows.known(userId: "u1", account: "a@x.test")
        XCTAssertEqual(known.count, EmailCategoryRows.maxCategories)
        XCTAssertEqual(known.first?.name, "c21")
        XCTAssertNil(try rows.category(userId: "u1", account: "a@x.test", name: "c0"))
        XCTAssertEqual(try rows.known(userId: "u2", account: "a@x.test").map(\.name), ["other"])
        try rows.purge(userId: "u1")
        XCTAssertTrue(try rows.known(userId: "u1", account: "a@x.test").isEmpty)
        XCTAssertEqual(try rows.known(userId: "u2", account: "a@x.test").count, 1)
    }

    func testPrepareSummarizesStoresTheCategoryAndRewritesItsPlaybook() async throws {
        let rows = try store()
        let fetched = message(parts: [part("text/plain", "Your receipt for $12.")], from: "Shop <receipts@shop.example>")
        let requests = RequestLog()
        let deps = P.Dependencies(
            read: { _, _ in fetched },
            respond: { body, _ in
                await requests.add(body)
                if body["text"].flatMap({ ($0 as? [String: Any])?["format"] as? [String: Any] })?["type"] as? String == "json_object" {
                    return #"{"playbook":"They archive receipts.","changed":true}"#
                }
                return #"{"summary":"Shop sent a receipt for twelve dollars.","suggestedAction":null,"archiveScope":"message","categoryGuess":{"name":"receipt","description":"Purchase receipts"},"reason":null}"#
            },
            decide: { _ in XCTFail("no known categories yet"); return [:] },
            count: { _, _, _ in 0 },
            timeZone: { _ in "America/Los_Angeles" },
            userId: { "u1" }, store: rows, draftsOnly: { _ in true })
        let key = LiveEmailPresentation.Key(account: "owner@example.test", threadId: "t1", messageId: "m1",
                                            exchangeId: "", messageIDs: ["m1"], selectedIDs: ["m1"])
        let scope = ProfileRuntime.Scope(profileId: "p", isDefault: true, emails: ["owner@example.test"], suggestedActions: true)
        let prepared = try await P.prepare(key, scope: scope, deps: deps)
        XCTAssertEqual(prepared.summary, "Shop sent a receipt for twelve dollars.")
        XCTAssertEqual(prepared.suggestedQuestion, P.singleArchive)
        XCTAssertEqual(prepared.category, "receipt")
        XCTAssertEqual(prepared.sentAt, "2026-09-22T17:00:00.000Z")
        let first = await requests.bodies.first
        let summary = try XCTUnwrap(first)
        XCTAssertNil(summary["service_tier"])
        XCTAssertEqual(summary["model"] as? String, "gpt-5.6-luna")
        XCTAssertEqual(try rows.known(userId: "u1", account: "owner@example.test").map(\.description), ["Purchase receipts"])

        let changed = await P.reportPlaybook(account: " Owner@example.test ", category: "receipt",
            turns: [("user", "archive it"), ("assistant", "Done.")], tools: ["archive_message", "Bad-Name"], deps: deps)
        XCTAssertTrue(changed)
        XCTAssertEqual(try rows.category(userId: "u1", account: "owner@example.test", name: "receipt")?.playbook,
                       "They archive receipts.")
        let last = await requests.bodies.last
        let rewrite = try XCTUnwrap(last)
        XCTAssertNil(rewrite["service_tier"])
        XCTAssertTrue((rewrite["input"] as? String ?? "").contains(#"Tools used while this email was current: ["archive_message"]"#))
        let unknown = await P.reportPlaybook(account: "owner@example.test", category: "newsletter",
                                             turns: [("user", "archive it")], tools: [], deps: deps)
        XCTAssertFalse(unknown)
    }

    func testPrepareRejectsAMessageFromAnotherThread() async throws {
        let deps = P.Dependencies(
            read: { _, _ in self.message(thread: "elsewhere", parts: [self.part("text/plain", "Hi")]) },
            respond: { _, _ in XCTFail("no summary for a rejected chain"); return "" },
            decide: { _ in [:] }, count: { _, _, _ in 0 }, timeZone: { _ in nil }, userId: { nil },
            store: try store(), draftsOnly: { _ in true })
        let key = LiveEmailPresentation.Key(account: "owner@example.test", threadId: "t1", messageId: "m1",
                                            exchangeId: "", messageIDs: ["m1"], selectedIDs: ["m1"])
        do {
            _ = try await P.prepare(key, scope: .init(profileId: "p", isDefault: true, emails: ["owner@example.test"]), deps: deps)
            XCTFail("expected a rejection")
        } catch let failure as P.Failure {
            XCTAssertEqual(failure.reason, "incomplete_email_context")
        }
    }
}

private actor RequestLog {
    var bodies: [[String: Any]] = []
    func add(_ body: [String: Any]) { bodies.append(body) }
}
