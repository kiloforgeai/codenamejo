import XCTest
@testable import CodenameJo

final class EmailInterpretationTests: XCTestCase {
    private let key = LiveEmailPresentation.Key(account: "qa@example.test", threadId: "thread", messageId: "selected",
        exchangeId: "", messageIDs: ["selected"], selectedIDs: ["selected"])
    private let step = #"{"done":false,"item":{"account":"qa@example.test","id":"selected","threadId":"thread","identity":"Sender","snippet":"Ordered! Newsletter signature","bodySummary":"Ordered the newsletter"}}"#

    private func message(_ id: String, body: String, thread: String = "thread", day: Int = 28) -> GmailAPI.FullMessage {
        let headers = [("From", "Sender <sender@example.test>"), ("To", "qa@example.test"),
            ("Subject", "Newsletter update"), ("Date", "Wed, \(day) Oct 2026 10:00:00 -0700")]
            .map { GmailAPI.MessageDetail.Header(name: $0.0, value: $0.1) }
        return .init(id: id, threadId: thread, labelIds: ["INBOX"], internalDate: nil,
            payload: .init(mimeType: "text/plain", filename: nil, headers: headers,
                body: .init(size: body.utf8.count, data: Data(body.utf8).base64EncodedString()), parts: nil))
    }

    func testAmbiguousReplyReadsOnlyCorrectBoundedAncestry() async throws {
        let selected = message("selected", body: "Ordered!\n\n--\nMy publication https://example.test/newsletter", day: 29)
        let earlier = (1...12).map { message("earlier-\($0)", body: "I recommend the book Reliable Systems. \($0)", day: $0) }
        let wrong = message("foreign", body: "SECRET OTHER THREAD", thread: "other")
        let future = message("future", body: "NOT EARLIER CONTEXT", day: 30)
        let deps = LocalEmailPresentation.Dependencies(read: { _, _ in selected }, respond: { body, _ in
            let input = try XCTUnwrap((body["input"] as? [[String: Any]])?.first?["content"] as? String)
            let data = try XCTUnwrap(input.data(using: .utf8))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
            XCTAssertEqual(messages.count, 6)
            XCTAssertTrue(input.contains("Reliable Systems"))
            XCTAssertFalse(input.contains("SECRET OTHER THREAD"))
            XCTAssertFalse(input.contains("NOT EARLIER CONTEXT"))
            return #"{"summary":"Sender confirms ordering the book you recommended."}"#
        }, timeZone: { _ in nil }, thread: { account, id in
            XCTAssertEqual(account, "qa@example.test")
            XCTAssertEqual(id, "thread")
            return earlier + [selected, wrong, future]
        })
        let result = try await LocalEmailPresentation.prepare(key, scope: .init(profileId: "p", isDefault: true), deps: deps)
        XCTAssertEqual(result.summaryProvenance, "thread_ancestry")
        XCTAssertTrue(result.summary.contains("book"))
    }

    func testLongThreadPreparesSelectedSchedulingMessageWithoutReadingAllContext() async throws {
        let context = (0..<27).map { ["id": "old-\($0)"] }
        let step = GmailReadTools.json(["done": false, "item": ["account": key.account,
            "id": key.messageId, "threadId": key.threadId, "identity": "Sender",
            "snippet": "Can we meet Nov 4-", "exchangeContext": context]])
        let keys = LiveEmailPreparationCache.candidates(current: step, readAhead: [])
        XCTAssertEqual(keys.count, 1)
        let bounded = try XCTUnwrap(keys.first)
        XCTAssertEqual(bounded.messageIDs, ["selected"])
        let full = message("selected", body: "Can we meet November 4–13, 2026 between 10 AM and 2 PM America/Los_Angeles? Do not schedule November 14.")
        let deps = LocalEmailPresentation.Dependencies(read: { account, id in
            XCTAssertEqual(account, self.key.account); XCTAssertEqual(id, "selected")
            return full
        }, respond: { body, _ in
            let text = try XCTUnwrap((body["input"] as? [[String: Any]])?.first?["content"] as? String)
            XCTAssertTrue(text.contains("November 4–13"))
            XCTAssertTrue(text.contains("Do not schedule November 14"))
            XCTAssertTrue(text.contains("America/Los_Angeles"))
            XCTAssertFalse(text.contains("old-26"))
            return #"{"summary":"Sender wants a meeting November 4–13, from 10 AM to 2 PM Pacific time, excluding November 14."}"#
        }, timeZone: { _ in "America/Los_Angeles" }, thread: { _, _ in
            XCTFail("A complete selected scheduling request needs no full-thread fetch"); return []
        })
        let prepared = try await LocalEmailPresentation.prepare(bounded,
            scope: .init(profileId: "p", isDefault: true), deps: deps)
        let line = try XCTUnwrap(LiveSpokenStepContract.line(step: step, lead: "", prepared: prepared))
        XCTAssertTrue(line.contains("November 4–13"))
        XCTAssertTrue(line.contains("excluding November 14"))
        var cache = LiveEmailPreparationCache(profileId: "p")
        cache.seed([prepared])
        XCTAssertNotNil(cache.ready(for: step, profileId: "p"))
        let opening = LiveEmailOpeningSummary(prepare: { _, _ in prepared })
        await opening.warm([bounded], scope: .init(profileId: "p", isDefault: true))
        await opening.awaitWarm()
        let warmed = await opening.ready(for: step, profileId: "p")
        XCTAssertNotNil(warmed, "Opening cache must match the bounded read to the same selected source")
    }

    func testIncompleteSourceAndOversizedSummaryCannotBecomePreparedFacts() async throws {
        for source in [message("selected", body: String(repeating: "Details. ", count: 3_000) + "Do not schedule."),
                       message("selected", body: "a{color:red;} b{margin:0;} c{padding:0;}")] {
            let deps = LocalEmailPresentation.Dependencies(read: { _, _ in source }, respond: { _, _ in
                XCTFail("Incomplete source must not reach the summary model"); return ""
            }, timeZone: { _ in nil })
            do {
                _ = try await LocalEmailPresentation.prepare(key, scope: .init(profileId: "p", isDefault: true), deps: deps)
                XCTFail("Expected an incomplete-content refusal")
            } catch { XCTAssertTrue(error.localizedDescription.contains("incomplete_email_context")) }
        }
        for fragment in ["We can meet Nov 4-", "The fee is $", "Proceed if", "This does not"] {
            let step = GmailReadTools.json(["done": false, "item": ["account": key.account,
                "id": key.messageId, "threadId": key.threadId, "identity": "Sender", "snippet": fragment]])
            let line = try XCTUnwrap(LiveSpokenStepContract.line(step: step, lead: ""))
            XCTAssertFalse(line.contains(fragment))
            XCTAssertTrue(line.contains("reliable summary"))
        }
    }

    func testMissingAncestryCannotInventObjectFromSubjectOrSignature() async throws {
        for body in ["Ordered!\n\nNewsletter editor", "Sounds good\n\nhttps://example.test/publication", "That works!"] {
            let selected = message("selected", body: body)
            let deps = LocalEmailPresentation.Dependencies(read: { _, _ in selected }, respond: { _, _ in
                XCTFail("No speculative model summary without a referent"); return ""
            }, timeZone: { _ in nil })
            let result = try await LocalEmailPresentation.prepare(key, scope: .init(profileId: "p", isDefault: true), deps: deps)
            XCTAssertEqual(result.summaryProvenance, "uncertain_missing_ancestry")
            XCTAssertTrue(result.summary.contains("unavailable"))
            XCTAssertFalse(result.summary.contains("newsletter"))
        }
    }

    func testExplicitCorrectionSuppliesProvenanceWithoutChangingSource() async throws {
        let selected = message("selected", body: "Ordered!")
        let deps = LocalEmailPresentation.Dependencies(read: { _, _ in selected }, respond: { body, _ in
            let input = try XCTUnwrap((body["input"] as? [[String: Any]])?.first?["content"] as? String)
            XCTAssertTrue(input.contains("explicit_user_statement"))
            XCTAssertTrue(input.contains("a book, not the newsletter"))
            XCTAssertTrue(input.contains("Ordered!"))
            return #"{"summary":"You clarified that Sender ordered a book."}"#
        }, timeZone: { _ in nil })
        let result = try await LocalEmailPresentation.prepare(key, scope: .init(profileId: "p", isDefault: true),
            deps: deps, correction: "It was a book, not the newsletter.")
        XCTAssertEqual(result.summaryProvenance, "user_correction")
        XCTAssertEqual(result.emailContent?.messages.first?.text, "Ordered!")
    }

    func testHeadersOnlyNeverReadsSourceOrAncestry() async throws {
        let deps = LocalEmailPresentation.Dependencies(read: { _, _ in XCTFail("Body withheld"); throw CancellationError() },
            respond: { _, _ in XCTFail("Body withheld"); return "" }, timeZone: { _ in nil },
            thread: { _, _ in XCTFail("Thread withheld"); return [] })
        do {
            _ = try await LocalEmailPresentation.prepare(key, scope: .init(profileId: "p", isDefault: true, mailHeadersOnly: true), deps: deps)
            XCTFail("Expected refusal")
        } catch let error as LocalEmailPresentation.Failure { XCTAssertEqual(error.reason, "body_access_withheld") }
    }

    func testCorrectionRejectsLateSummaryAndSurvivesRevisitAndReversal() throws {
        var cache = LiveEmailPreparationCache(profileId: "p")
        let old = LiveEmailPresentation(key: key, summary: "Ordered the newsletter", from: "Sender", to: "Owner", sentAt: "")
        cache.seed([old])
        let generation = cache.generation
        cache.correct(key, text: "A book, not the newsletter")
        XCTAssertNotEqual(generation, cache.generation)
        cache.seed([old])
        cache.entries[key.identity] = (old, Date())
        XCTAssertNil(cache.ready(for: step, profileId: "p"))
        let annotated = cache.annotatingCorrection(step)
        XCTAssertFalse(annotated.contains("Ordered the newsletter"))
        XCTAssertTrue(annotated.contains("A book, not the newsletter"))
        XCTAssertNil(old.speakerLine(for: annotated))
        XCTAssertNil(LiveSpokenStepContract.line(step: annotated, lead: "Next, ", prepared: old))
        var corrected = old
        corrected.correctionRevision = 1
        cache.entries[key.identity] = (corrected, Date())
        XCTAssertNotNil(cache.ready(for: step, profileId: "p"))
        cache.correct(key, text: "Actually it was the newsletter, not a book")
        XCTAssertNil(cache.ready(for: step, profileId: "p"))
        XCTAssertEqual(cache.corrections[key.identity]?.revision, 2)
        XCTAssertTrue(cache.annotatingCorrection(step).contains("Actually it was the newsletter"))
    }

    func testCorrectionsDoNotCrossAccountMessageOrProfile() {
        var cache = LiveEmailPreparationCache(profileId: "p")
        cache.correct(key, text: "It is a book, not a newsletter")
        for other in [step.replacingOccurrences(of: "qa@example.test", with: "other@example.test"),
                      step.replacingOccurrences(of: "selected", with: "different")] {
            XCTAssertEqual(cache.annotatingCorrection(other), other)
        }
        XCTAssertNil(cache.ready(for: step, profileId: "other"))
        XCTAssertTrue(LiveEmailPreparationCache.isFactualCorrection("Feedback: it was a book, not the newsletter."))
        XCTAssertTrue(LiveEmailPreparationCache.isFactualCorrection("A book, not the newsletter."))
        XCTAssertFalse(LiveEmailPreparationCache.isFactualCorrection("Do not archive it."))
        XCTAssertFalse(LiveEmailPreparationCache.isFactualCorrection("Feedback: the archive button is slow."))
    }

    @MainActor
    func testClientKeepsCorrectionThroughCacheResetButClearsAtCallEnd() {
        ProfileRuntime.install(nil)
        let client = FullDuplexVoiceClient()
        client.standingStep = step
        client.captureEmailCorrection("Feedback: it was a book, not the newsletter.")
        XCTAssertTrue(client.preparedEmailStep(step).contains("explicit_user_statement"))
        client.resetLivePreparation()
        XCTAssertTrue(client.preparedEmailStep(step).contains("a book, not the newsletter"))
        ProfileRuntime.install(.init(profileId: "other", isDefault: false))
        XCTAssertFalse(client.preparedEmailStep(step).contains("explicit_user_statement"))
        ProfileRuntime.install(nil)
        client.resetLivePreparation(keepingCorrections: false)
        XCTAssertFalse(client.preparedEmailStep(step).contains("explicit_user_statement"))
    }
}
