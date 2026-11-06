import XCTest
@testable import CodenameJo

@MainActor
final class DesktopEmailReaderTests: XCTestCase {
    private func request(_ id: String = "selected", profile: String = "work", headersOnly: Bool = false) -> DesktopEmailReader.Request {
        .init(selection: .init(account: "reader@example.test", messageID: id), threadID: "thread",
              ownerID: "owner", profileID: profile, conversationID: nil, headersOnly: headersOnly)
    }

    private func part(_ text: String, mime: String = "text/plain", filename: String? = nil) -> GmailAPI.FullPart {
        .init(mimeType: mime, filename: filename, headers: nil,
              body: .init(size: text.utf8.count, data: Data(text.utf8).base64EncodedString()), parts: nil)
    }

    private func message(_ id: String = "selected", body: GmailAPI.FullPart, date: String = "10", thread: String = "thread") -> GmailAPI.FullMessage {
        .init(id: id, threadId: thread, labelIds: ["INBOX", "UNREAD"], internalDate: date, payload: body)
    }

    private func content(_ id: String) -> DesktopEmailReader.Content {
        .init(selectedID: id, messages: [.init(id: id, from: "Sender", to: "", cc: "", subject: id, date: "",
                                             body: AttributedString("Complete \(id)"), attachments: [], error: nil)])
    }

    func testCompleteLongBodiesAndQuotedRepliesAreNotTruncatedToTheSnippet() async throws {
        let text = "FIRST\n\n" + String(repeating: "A complete paragraph.\n\n", count: 2_000)
            + "On Monday someone wrote:\n> The original reply.\nFINAL"
        let decoded = try await DesktopEmailReader.decode(.init(id: "thread", messages: [message(body: part(text))]),
            request: request(), attachment: { _, _ in XCTFail("Unexpected attachment read"); return Data() })
        XCTAssertGreaterThan(text.utf8.count, 24_000)
        XCTAssertEqual(decoded.messages.first?.text, text)
        XCTAssertNil(decoded.messages.first?.error)
    }

    func testThreadContainsEveryMessageInOrderAndPreservesTheSelectedIdentity() async throws {
        let messages = (1...18).reversed().map { index in
            message(index == 9 ? "selected" : "m\(index)", body: part("Body \(index)"), date: String(index))
        }
        let decoded = try await DesktopEmailReader.decode(.init(id: "thread", messages: messages),
            request: request(), attachment: { _, _ in Data() })
        XCTAssertEqual(decoded.messages.count, 18, "A thread is not the voice preparation's twelve-message sample")
        XCTAssertEqual(decoded.messages.first?.text, "Body 1")
        XCTAssertEqual(decoded.messages.last?.text, "Body 18")
        XCTAssertEqual(decoded.selectedID, "selected")
        XCTAssertEqual(decoded.messages[8].id, "selected")
    }

    func testHTMLLinksListsAndExternalBodyPartsRemainReadableWithoutLoadingFiles() async throws {
        let html = "<p>FIRST &amp; &#x1F642;</p><ul><li>One</li><li>Two</li></ul>"
            + "<p><a href=\"https://example.test/detail\">Details</a></p><script>bad()</script><p>FINAL</p>"
        let external = GmailAPI.FullPart(mimeType: "text/html", filename: nil, headers: nil,
            body: .init(size: html.utf8.count, data: nil, attachmentId: "body"), parts: nil)
        let file = part("File contents must not be read", filename: "notes.txt")
        let mixed = GmailAPI.FullPart(mimeType: "multipart/mixed", filename: nil, headers: nil, body: nil, parts: [external, file])
        var fetched: [String] = []
        let decoded = try await DesktopEmailReader.decode(.init(id: "thread", messages: [message(body: mixed)]),
            request: request(), attachment: { messageID, id in fetched.append("\(messageID):\(id)"); return Data(html.utf8) })
        let text = try XCTUnwrap(decoded.messages.first?.text)
        XCTAssertTrue(text.contains("FIRST & 🙂"))
        XCTAssertTrue(text.contains("• One\n• Two"))
        XCTAssertTrue(text.contains("Details (https://example.test/detail)"))
        XCTAssertEqual(decoded.messages[0].body.runs.compactMap(\.link), [URL(string: "https://example.test/detail")!])
        XCTAssertTrue(text.contains("FINAL"))
        XCTAssertFalse(text.contains("bad()"))
        XCTAssertFalse(text.contains("File contents"))
        XCTAssertEqual(fetched, ["selected:body"])
    }

    func testPlainEmailLinksPreserveUnicodeParagraphsQuotedRepliesAndDestinations() async throws {
        let text = "🙂 Café — published yesterday! https://lnkd.in/p/eyAWMxPb\n\n"
            + "On Monday someone wrote:\n> Details (https://example.com/path?q=one&other=two#section).\n"
            + "> Contact reader@example.com or visit www.example.org.\nFINAL"
        let decoded = try await DesktopEmailReader.decode(.init(id: "thread", messages: [message(body: part(text))]),
            request: request(), attachment: { _, _ in Data() })
        let body = try XCTUnwrap(decoded.messages.first?.body)
        XCTAssertEqual(String(body.characters), text)
        let links = body.runs.compactMap { run -> (String, String)? in
            guard let url = run.link else { return nil }
            return (String(body[run.range].characters), url.absoluteString)
        }
        XCTAssertEqual(links.map(\.0), ["https://lnkd.in/p/eyAWMxPb", "https://example.com/path?q=one&other=two#section",
                                       "reader@example.com", "www.example.org"])
        XCTAssertEqual(links.map(\.1), ["https://lnkd.in/p/eyAWMxPb", "https://example.com/path?q=one&other=two#section",
                                       "mailto:reader@example.com", "http://www.example.org"])
    }

    func testEveryThreadMessageKeepsItsOwnLinks() async throws {
        let decoded = try await DesktopEmailReader.decode(.init(id: "thread", messages: [
            message("earlier", body: part("Earlier: https://example.com/first"), date: "1"),
            message(body: part("Selected: https://example.com/second"))]),
            request: request(), attachment: { _, _ in Data() })
        XCTAssertEqual(decoded.messages.map { $0.body.runs.compactMap { $0.link?.absoluteString } },
                       [["https://example.com/first"], ["https://example.com/second"]])
    }

    func testEmailTextIsNotInterpretedAsMarkdownOrExecutableLinks() throws {
        let text = "*Keep literal markup* [a label](javascript:alert(1))\nfile:///tmp/private.txt\ncustomapp://run/action"
        let body = try DesktopEmailReader.linkedBody(text)
        XCTAssertEqual(String(body.characters), text)
        XCTAssertTrue(body.runs.compactMap(\.link).isEmpty)
    }

    func testPlainAlternativeIsShownOnceAndMissingBodiesAreExplicitFailures() async throws {
        let alternative = GmailAPI.FullPart(mimeType: "multipart/alternative", filename: nil, headers: nil, body: nil,
            parts: [part("Complete plain version"), part("<p>Duplicate HTML version</p>", mime: "text/html")])
        let missing = GmailAPI.FullPart(mimeType: "text/plain", filename: nil, headers: nil,
            body: .init(size: 100, data: nil), parts: nil)
        let decoded = try await DesktopEmailReader.decode(.init(id: "thread", messages: [
            message(body: alternative), message("missing", body: missing, date: "20")]),
            request: request(), attachment: { _, _ in Data() })
        XCTAssertEqual(decoded.messages[0].text, "Complete plain version")
        XCTAssertNil(decoded.messages[0].error)
        XCTAssertTrue(decoded.messages[1].text.isEmpty)
        XCTAssertTrue(decoded.messages[1].error?.contains("incomplete") == true)
    }

    func testHTMLNoticeUsesArticleAcrossReaderToolAndPreparation() async throws {
        let html = "<h1>FIRST &amp; article</h1><p>MIDDLE paragraph</p><ul><li>One</li><li>Two</li></ul>"
            + "<p><a href=\"https://example.test/long-tracking-token\">Details</a></p>"
            + "<script>hiddenScript()</script><div style=\"display:none\">hidden preheader</div><p>FINAL</p>"
        let related = GmailAPI.FullPart(mimeType: "multipart/related", filename: nil, headers: nil, body: nil,
            parts: [part(html, mime: "text/html"), part("attachment secret", filename: "notes.txt")])
        for notice in ["Your email software can't display HTML emails. https://example.test/tracking",
                       "This message was sent in HTML. Please use a browser.",
                       "To view this email in your browser visit https://example.test/tracking", " \n "] {
            let mime = GmailAPI.FullPart(mimeType: "multipart/alternative", filename: nil, headers: nil, body: nil,
                parts: [part(notice), related])
            let selected = message(body: mime)
            let prepared = LocalEmailPresentation.envelope(selected, authorship: false)
            for text in [MailBodyText.plainText(mime), GmailReadTools.envelope(selected)["body"] as? String ?? "",
                         prepared.body, try XCTUnwrap(prepared.source).text] {
                XCTAssertTrue(text.contains("FIRST & article"))
                XCTAssertTrue(text.contains("MIDDLE paragraph"))
                XCTAssertTrue(text.contains("FINAL"))
                XCTAssertFalse(text.contains("display HTML"))
                XCTAssertFalse(text.contains("https://"), "Preparation keeps link labels without spelling tracking URLs")
                XCTAssertFalse(text.contains("hidden"))
                XCTAssertFalse(text.contains("attachment secret"))
            }
            let decoded = try await DesktopEmailReader.decode(.init(id: "thread", messages: [selected]),
                request: request(), attachment: { _, _ in XCTFail("No remote content required"); return Data() })
            XCTAssertEqual(decoded.selectedID, "selected")
            XCTAssertTrue(decoded.messages[0].text.hasSuffix("FINAL"))
            XCTAssertTrue(decoded.messages[0].text.contains("• One\n• Two"))
            XCTAssertEqual(decoded.messages[0].body.runs.compactMap(\.link), [URL(string: "https://example.test/long-tracking-token")!])
        }
    }

    func testHTMLFallbackDoesNotReplaceRealTextOrExposeHiddenOnlyAlternative() async throws {
        for (plain, html, expected) in [
            ("Short real reply.", "<p>" + String(repeating: "Long duplicate. ", count: 100) + "</p>", "Short real reply."),
            ("Your email software can't display HTML emails.", "<script>secret()</script>", "Your email software can't display HTML emails."),
            ("", "<p>Malformed but readable &amp; complete", "Malformed but readable & complete")
        ] {
            let mime = GmailAPI.FullPart(mimeType: "multipart/alternative", filename: nil, headers: nil, body: nil,
                parts: [part(plain), part(html, mime: "text/html")])
            XCTAssertEqual(MailBodyText.plainText(mime), expected)
            XCTAssertEqual(LocalEmailPresentation.flattenBody(mime).text, expected)
            let decoded = try await DesktopEmailReader.decode(.init(id: "thread", messages: [message(body: mime)]),
                request: request(), attachment: { _, _ in Data() })
            XCTAssertEqual(decoded.messages[0].text, expected)
        }
    }

    func testExternalHTMLFallbackLoadsCompleteArticleOnRepeatedReadsAndReportsFailure() async throws {
        let html = "<p>FIRST</p>" + String(repeating: "<p>Article paragraph.</p>", count: 4_000) + "<p>FINAL</p>"
        let external = GmailAPI.FullPart(mimeType: "text/html", filename: nil, headers: nil,
            body: .init(size: html.utf8.count, data: nil, attachmentId: "article"), parts: nil)
        let mime = GmailAPI.FullPart(mimeType: "multipart/alternative", filename: nil, headers: nil, body: nil,
            parts: [part("Your email software cannot display HTML emails."), external])
        for _ in 0..<2 {
            let decoded = try await DesktopEmailReader.decode(.init(id: "thread", messages: [message(body: mime)]),
                request: request(), attachment: { id, bodyID in
                    XCTAssertEqual(id, "selected"); XCTAssertEqual(bodyID, "article"); return Data(html.utf8)
                })
            XCTAssertTrue(decoded.messages[0].text.hasPrefix("FIRST"))
            XCTAssertTrue(decoded.messages[0].text.hasSuffix("FINAL"))
            XCTAssertGreaterThan(decoded.messages[0].text.count, 24_000)
        }
        let failed = try await DesktopEmailReader.decode(.init(id: "thread", messages: [message(body: mime)]),
            request: request(), attachment: { _, _ in throw URLError(.timedOut) })
        XCTAssertNotNil(failed.messages[0].error)
        XCTAssertFalse(failed.messages[0].text.contains("cannot display"))
    }

    func testWrongThreadMissingSelectionAndDuplicateMessagesFailClosed() async {
        for messages in [[message("other", body: part("Wrong email"))],
                         [message(body: part("Wrong thread"), thread: "other")],
                         [message(body: part("First")), message(body: part("Duplicate"))]] {
            do {
                _ = try await DesktopEmailReader.decode(.init(id: "thread", messages: messages),
                    request: request(), attachment: { _, _ in Data() })
                XCTFail("An invalid thread must not be presented")
            } catch { XCTAssertTrue(error.localizedDescription.contains("complete thread")) }
        }
    }

    func testLateSelectionAndProfileResponsesCannotReplaceTheCurrentReader() async throws {
        for current in [request("B"), request("A", profile: "personal")] {
            let gate = ReaderGate()
            let reader = DesktopEmailReader(loader: { try await gate.load($0) }, allowed: { _ in true })
            let old = request("A")
            reader.show(old)
            try await waitFor { await gate.contains(old) }
            reader.show(current)
            try await waitFor { await gate.contains(current) }
            await gate.finish(current, with: .success(content("current")))
            try await waitFor { reader.state == .ready(current, self.content("current")) }
            await gate.finish(old, with: .success(content("stale")))
            try await Task.sleep(for: .milliseconds(20))
            XCTAssertEqual(reader.state, .ready(current, content("current")))
            reader.show(nil)
            XCTAssertEqual(reader.state, .idle)
        }
    }

    func testAccessLostDuringAReadCannotPublishItsBody() async throws {
        let gate = ReaderGate()
        var allowed = true
        let reader = DesktopEmailReader(loader: { try await gate.load($0) }, allowed: { _ in allowed })
        let selected = request()
        reader.show(selected)
        try await waitFor { await gate.contains(selected) }
        allowed = false
        await gate.finish(selected, with: .success(content("must not appear")))
        try await waitFor { reader.state == .idle }
        XCTAssertEqual(reader.state, .idle)
    }

    func testClearingTheReaderCancelsAndIgnoresAnUncooperativeLoad() async throws {
        let gate = ReaderGate()
        let reader = DesktopEmailReader(loader: { try await gate.load($0) }, allowed: { _ in true })
        let selected = request()
        reader.show(selected)
        try await waitFor { await gate.contains(selected) }
        reader.show(nil)
        await gate.finish(selected, with: .success(content("late")))
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(reader.state, .idle)
    }

    func testHeadersOnlyAndRevokedAccessDoNotLoadAndClearVisibleBodies() async throws {
        var allowed = true
        let reader = DesktopEmailReader(loader: { _ in XCTFail("Headers-only must not load content"); throw CancellationError() },
                                       allowed: { _ in allowed })
        let headers = request(headersOnly: true)
        reader.show(headers)
        XCTAssertEqual(reader.state, .headersOnly(headers))
        allowed = false
        reader.show(headers)
        guard case .failed(let failedRequest, _) = reader.state else {
            return XCTFail("Revalidate access and clear content even if the selected ID has not changed")
        }
        XCTAssertEqual(failedRequest, headers)
    }

    func testFailedReadCanRetryAndRepeatedSelectionDoesNotFetchAgain() async throws {
        let gate = ReaderGate()
        let reader = DesktopEmailReader(loader: { try await gate.load($0) }, allowed: { _ in true })
        let selected = request()
        reader.show(selected)
        try await waitFor { await gate.contains(selected) }
        await gate.finish(selected, with: .failure(URLError(.timedOut)))
        try await waitFor { if case .failed = reader.state { return true }; return false }
        reader.show(selected, retry: true)
        try await waitFor { await gate.contains(selected) }
        await gate.finish(selected, with: .success(content("selected")))
        try await waitFor { reader.state == .ready(selected, self.content("selected")) }
        reader.show(selected)
        let calls = await gate.calls
        XCTAssertEqual(calls, 2)
    }

    func testStartingConversationReusesLoadedBodyOnlyWithinItsAuthorizedScope() async throws {
        let gate = ReaderGate()
        var allowed = true
        let reader = DesktopEmailReader(loader: { try await gate.load($0) }, allowed: { _ in allowed })
        let preview = request()
        reader.show(preview)
        try await waitFor { await gate.contains(preview) }
        await gate.finish(preview, with: .success(content("selected")))
        try await waitFor { reader.state == .ready(preview, self.content("selected")) }
        let live = DesktopEmailReader.Request(selection: preview.selection, threadID: preview.threadID,
            ownerID: preview.ownerID, profileID: preview.profileID, conversationID: UUID(), headersOnly: false)
        reader.show(live)
        XCTAssertEqual(reader.state, .ready(live, content("selected")), "No loading flash for the same authorized content")
        let calls = await gate.calls
        XCTAssertEqual(calls, 1)
        allowed = false
        reader.show(preview)
        guard case .failed = reader.state else { return XCTFail("Lost access must clear even a cached body") }
    }

    func testWorkspaceReadsTheDisplayedEmailDuringTransitionAndClearsOnProfileSwitch() {
        let model = DesktopWorkspaceModel()
        model.profileID = "work"
        model.conversationID = UUID()
        model.inSession = true
        model.sessionFeed = .init(current: .init(account: "reader@example.test", messageID: "A"))
        model.focus = .email(.init(sender: "A", subject: "A", snippet: "truncated", account: "reader@example.test",
                                  position: 1, total: 2, messageId: "A", threadId: "thread"))
        XCTAssertEqual(model.readerRequest(ownerID: "owner", headersOnly: false)?.selection.messageID, "A")
        model.focus = .email(.init(sender: "B", subject: "B", snippet: "truncated", account: "reader@example.test",
                                  position: 2, total: 2, messageId: "B", threadId: "thread-b"))
        XCTAssertEqual(model.readerRequest(ownerID: "owner", headersOnly: false)?.selection.messageID, "A")
        model.sessionFeed.current = .init(account: "reader@example.test", messageID: "B")
        XCTAssertEqual(model.readerRequest(ownerID: "owner", headersOnly: false)?.selection.messageID, "B")
        model.profileID = "personal"
        XCTAssertNil(model.readerRequest(ownerID: "owner", headersOnly: false))
        XCTAssertEqual(model.emailReader, .idle)
    }

    private func waitFor(_ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !(await condition()) {
            guard Date() < deadline else { XCTFail("Reader did not reach the expected state"); return }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private actor ReaderGate {
    private var pending: [DesktopEmailReader.Request: CheckedContinuation<DesktopEmailReader.Content, Error>] = [:]
    var calls = 0
    func load(_ request: DesktopEmailReader.Request) async throws -> DesktopEmailReader.Content {
        calls += 1
        return try await withCheckedThrowingContinuation { pending[request] = $0 }
    }
    func contains(_ request: DesktopEmailReader.Request) -> Bool { pending[request] != nil }
    func finish(_ request: DesktopEmailReader.Request, with result: Result<DesktopEmailReader.Content, Error>) {
        pending.removeValue(forKey: request)?.resume(with: result)
    }
}
