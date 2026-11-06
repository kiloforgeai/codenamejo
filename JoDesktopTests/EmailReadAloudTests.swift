import XCTest
@testable import CodenameJo

final class EmailReadAloudTests: XCTestCase {
    private let selection = MailSelection(account: "reader@example.test", messageID: "selected")
    private func part(_ text: String, mime: String = "text/plain", filename: String? = nil) -> GmailAPI.FullPart {
        .init(mimeType: mime, filename: filename, headers: nil,
              body: .init(size: text.utf8.count, data: Data(text.utf8).base64EncodedString()), parts: nil)
    }
    private func message(_ payload: GmailAPI.FullPart, id: String = "selected") -> GmailAPI.FullMessage {
        .init(id: id, threadId: "selected-thread", labelIds: nil, internalDate: nil, payload: payload)
    }
    private func prepared(_ text: String, complete: Bool = true, fullRead: Bool? = true) -> FeedEmailContent.Message {
        .init(id: "selected", threadId: "selected-thread", from: "", to: "", cc: "", subject: "", date: "",
              text: text, textComplete: complete, attachments: [], fullReadComplete: fullRead)
    }
    private func read(_ payload: GmailAPI.FullPart) async throws -> String {
        try await FullEmailSource.read(selection: selection, threadID: "selected-thread", prepared: nil,
            fetch: { self.message(payload) }, attachment: { _ in XCTFail("Unexpected attachment read"); return Data() }).text
    }

    func testCompletePlainPreparedMessageNeedsNoProviderCalls() async throws {
        var fetches = 0
        let text = "First marker.\n\nThe complete selected message. Final marker."
        let result = try await FullEmailSource.read(selection: selection, threadID: "selected-thread", prepared: prepared(text),
            fetch: { fetches += 1; return self.message(self.part("Wrong content")) }, attachment: { _ in Data() })
        XCTAssertEqual(result.text, text)
        XCTAssertTrue(result.cached)
        XCTAssertEqual(fetches, 0)
    }

    func testPartialAndLegacyPreparedTextAlwaysRetrieveTheSelectedFullSource() async throws {
        for cache in [prepared("Only the beginning", complete: false), prepared("Only visible HTML labels", fullRead: nil)] {
            var fetches = 0
            let result = try await FullEmailSource.read(selection: selection, threadID: "selected-thread", prepared: cache,
                fetch: { fetches += 1; return self.message(self.part("Complete source. Final marker.")) }, attachment: { _ in Data() })
            XCTAssertEqual(result.text, "Complete source. Final marker.")
            XCTAssertFalse(result.cached)
            XCTAssertEqual(fetches, 1)
        }
    }

    func testLongForwardedAndQuotedBodyIsNotTrimmedAtEitherOldLimit() async throws {
        let text = "FIRST MARKER\n" + String(repeating: "Own words with the original checkpoint intact. ", count: 500)
            + "\nMIDDLE MARKER\nOn Tuesday someone wrote:\n" + String(repeating: "> Quoted words remain.\n", count: 900) + "FINAL MARKER"
        XCTAssertGreaterThan(text.utf8.count, 24_000)
        let actual = try await read(part(text))
        XCTAssertEqual(actual, text)
        let chunks = EmailReadAloud.split(actual)
        XCTAssertEqual(chunks.joined(), text)
        XCTAssertTrue(chunks.allSatisfy { $0.utf8.count <= 800 })
    }

    func testHTMLPreservesParagraphsListsEntitiesAndMeaningfulLinks() async throws {
        let html = """
        <html><head><style>.hidden{display:none}</style></head><body>
        <p>FIRST &amp; &#x1F642;</p><ul><li>One</li><li>Two &euro;</li></ul>
        <p><a href="https://example.test/path?a=1&amp;b=2">Read the details</a></p>
        <p hidden>SECRET HIDDEN</p><script>doNotRead()</script><p>FINAL &quot;marker&quot;</p>
        </body></html>
        """
        let actual = try await read(part(html, mime: "text/html"))
        XCTAssertTrue(actual.contains("FIRST & 🙂"))
        XCTAssertTrue(actual.contains("• One\n• Two €"))
        XCTAssertTrue(actual.contains("Read the details (https://example.test/path?a=1&b=2)"))
        XCTAssertTrue(actual.contains("FINAL \"marker\""))
        XCTAssertFalse(actual.contains("SECRET HIDDEN"))
        XCTAssertFalse(actual.contains("doNotRead"))
    }

    func testAlternativeIsNotDuplicatedAndAttachedFilesAreNotRead() async throws {
        let alternative = GmailAPI.FullPart(mimeType: "multipart/alternative", filename: nil, headers: nil, body: nil,
            parts: [part("Plain complete"), part("<p>HTML duplicate</p>", mime: "text/html")])
        let mixed = GmailAPI.FullPart(mimeType: "multipart/mixed", filename: nil, headers: nil, body: nil,
            parts: [alternative, part("Inline final section"), part("Private attachment", filename: "notes.txt")])
        let actual = try await read(mixed)
        XCTAssertEqual(actual, "Plain complete\n\nInline final section")
        XCTAssertFalse(FullEmailSource.completeInlinePlain(mixed))
        XCTAssertTrue(FullEmailSource.completeInlinePlain(part("Simple complete body")))
    }

    func testExternalTextBodyIsRetrievedAndCompletenessChecked() async throws {
        let text = "External body FIRST and FINAL"
        let payload = GmailAPI.FullPart(mimeType: "text/plain", filename: nil, headers: nil,
            body: .init(size: text.utf8.count, data: nil, attachmentId: "body-id"), parts: nil)
        var attachments: [String] = []
        let result = try await FullEmailSource.read(selection: selection, threadID: "selected-thread", prepared: nil,
            fetch: { self.message(payload) }, attachment: { id in attachments.append(id); return Data(text.utf8) })
        XCTAssertEqual(result.text, text)
        XCTAssertEqual(attachments, ["body-id"])
        do {
            _ = try await FullEmailSource.read(selection: selection, threadID: "selected-thread", prepared: nil,
                fetch: { self.message(payload) }, attachment: { _ in Data("Partial".utf8) })
            XCTFail("Partial source must fail, not claim completeness")
        } catch { XCTAssertTrue(error.localizedDescription.contains("incomplete")) }
    }

    func testRetrievalFailureThenYesReallyRetriesTheSameMessage() async throws {
        var fetches = 0
        func attempt() async throws -> String {
            try await FullEmailSource.read(selection: selection, threadID: "selected-thread", prepared: prepared("Partial", complete: false),
                fetch: {
                    fetches += 1
                    if fetches == 1 { throw URLError(.timedOut) }
                    return self.message(self.part("First through final marker."))
                }, attachment: { _ in Data() }).text
        }
        do { _ = try await attempt(); XCTFail("Expected timeout") } catch { XCTAssertTrue(error is URLError) }
        XCTAssertEqual(EmailReadAloud.intent("Yes", retryPending: true), .retry)
        let result = try await attempt()
        XCTAssertEqual(result, "First through final marker.")
        XCTAssertEqual(fetches, 2)
        XCTAssertNil(EmailReadAloud.intent("Yes", retryPending: false))
    }

    func testWrongMessageAndMissingBodyRefuseWithoutReadingAnotherThreadMember() async throws {
        do {
            _ = try await FullEmailSource.read(selection: selection, threadID: "selected-thread", prepared: nil,
                fetch: { self.message(self.part("Wrong thread member"), id: "other") }, attachment: { _ in Data() })
            XCTFail("Wrong target accepted")
        } catch { XCTAssertTrue(error.localizedDescription.contains("different message")) }
        let missing = GmailAPI.FullPart(mimeType: "text/plain", filename: nil, headers: nil, body: .init(size: 200, data: nil), parts: nil)
        do { _ = try await read(missing); XCTFail("Missing source accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("incomplete")) }
    }

    func testOrderedPlaybackRequiresBothAudioAndFullTranscriptCoverage() {
        var reading = EmailReadAloud(selection: selection, threadID: "selected-thread", profileID: "work", ownerID: "owner")
        let text = String(repeating: "First middle final words.\n", count: 100)
        reading.install(text, cached: false)
        var completed: [String] = []
        while let chunk = reading.queue() {
            reading.observeTranscript(chunk)
            XCTAssertFalse(reading.finishChunk(), "Queued/transcribed text alone is not audible completion")
            reading.observeAudio()
            XCTAssertTrue(reading.finishChunk())
            completed.append(chunk)
        }
        XCTAssertEqual(completed.joined(), text)
        XCTAssertEqual(reading.phase, .completed)
        XCTAssertEqual(reading.completedBytes, text.utf8.count)
    }

    func testInterruptionResumesUnfinishedChunkWithoutRepeatingCompletedChunks() {
        var reading = EmailReadAloud(selection: selection, threadID: "selected-thread", profileID: "work", ownerID: "owner")
        reading.install(String(repeating: "Sentence with retained progress. ", count: 80), cached: true)
        let first = reading.queue()!
        reading.observeAudio(); reading.observeTranscript(first)
        XCTAssertTrue(reading.finishChunk())
        let second = reading.queue()!
        reading.observeAudio(); reading.observeTranscript(String(second.prefix(20)))
        reading.pause()
        XCTAssertFalse(reading.finishChunk())
        XCTAssertEqual(reading.cursor, 1)
        XCTAssertEqual(reading.queue(), second)
        XCTAssertEqual(reading.completedBytes, first.utf8.count)
    }

    func testSummaryOrOmittedFinalMarkerCannotAdvanceReadingPosition() {
        var reading = EmailReadAloud(selection: selection, threadID: "selected-thread", profileID: nil, ownerID: nil)
        reading.install("FIRST. Every exact word. FINAL.", cached: true)
        _ = reading.queue(); reading.observeAudio(); reading.observeTranscript("FIRST. A short summary.")
        XCTAssertFalse(reading.finishChunk())
        XCTAssertEqual(reading.cursor, 0)
        XCTAssertNotEqual(reading.phase, .completed)
    }

    func testChunkingPreservesMultibyteTextAndOriginalOrdering() {
        let text = String(repeating: "🙂 café 日本語\n", count: 400)
        let chunks = EmailReadAloud.split(text)
        XCTAssertEqual(chunks.joined(), text)
        XCTAssertTrue(chunks.allSatisfy { $0.utf8.count <= 800 })
    }

    func testFullReadIntentsDoNotMatchQuestionsAboutReadingOrQualifiedRequests() {
        for text in ["Okay, can you read the whole email to me", "Read it in full", "Read this to me", "Could you read the full email please"] {
            XCTAssertEqual(EmailReadAloud.intent(text, retryPending: false), .start, text)
        }
        for text in ["Don't read this to me", "Read this to me and archive it", "Can you summarize this", "Why did you read the whole email"] {
            XCTAssertNil(EmailReadAloud.intent(text, retryPending: false), text)
        }
        XCTAssertEqual(EmailReadAloud.intent("Stop reading", retryPending: false), .pause)
        XCTAssertEqual(EmailReadAloud.intent("Keep reading", retryPending: false), .resume)
    }
}
