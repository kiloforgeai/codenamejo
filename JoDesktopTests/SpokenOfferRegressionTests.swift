import XCTest
@testable import CodenameJo

@MainActor
final class SpokenOfferRegressionTests: XCTestCase {
    func testOnlyKnownAnnotationsAreIgnoredAndQualifiedRefusalsStayRefusals() {
        for text in [" [inhale ]Yes", "[breath] yeah", "uh, [BREATH] sure", "sure, why not"] {
            XCTAssertEqual(FeedOfferAnswer.answer(to: text), .accepted, text)
            XCTAssertEqual(LiveCoachingAnswer.parse(text), .accepted, text)
        }
        for text in ["no", "yes, but not now", "[not] yes", "[don't] yes"] {
            XCTAssertEqual(FeedOfferAnswer.answer(to: text), .declined, text)
        }
        for text in ["[unknown] yes", "[archive] yes", "yes archive this", "hmm", "[inhale]"] {
            XCTAssertNil(FeedOfferAnswer.answer(to: text), text)
        }
    }

    func testAllOffersSurviveNoiseButConsumeOnAnswerSupersessionAndExpiry() {
        let now = Date()
        for kind in ["inbox", "cleanup"] {
            var offer: PendingFeedOffer? = PendingFeedOffer(now: now)
            let id = offer?.id
            XCTAssertEqual(FullDuplexVoiceClient.resolveFeedOffer(&offer, transcript: "[inhale] hmm", kind: kind, diagnostics: nil), .waiting)
            XCTAssertEqual(offer?.id, id)
            XCTAssertEqual(FullDuplexVoiceClient.resolveFeedOffer(&offer, transcript: "[breath] yeah", kind: kind, diagnostics: nil), .accepted)
            XCTAssertNil(offer)
            XCTAssertEqual(FullDuplexVoiceClient.resolveFeedOffer(&offer, transcript: "yes", kind: kind, diagnostics: nil), .expired)
            offer = PendingFeedOffer()
            XCTAssertEqual(FullDuplexVoiceClient.resolveFeedOffer(&offer, transcript: "yes, but not now", kind: kind, diagnostics: nil), .declined)
            offer = PendingFeedOffer()
            XCTAssertEqual(FullDuplexVoiceClient.resolveFeedOffer(&offer, transcript: "what is happening?", kind: kind, diagnostics: nil), .superseded)
            XCTAssertNil(offer)
        }
        var old = PendingFeedOffer(now: now)
        XCTAssertEqual(old.resolve("yes", now: now.addingTimeInterval(121)), .expired)
        var completion = LiveFeedCompletion(currentProfile: "Work", nextProfile: "Personal")
        completion.asked = true
        XCTAssertNil(completion.answer(to: "[breath] hmm"))
        XCTAssertEqual(completion.answer(to: "[inhale ]Yes"), .accepted)
        XCTAssertEqual(completion.answer(to: "yes, but not now"), .declined)
        XCTAssertEqual(completion.answer(to: "read this instead"), .cancelled)
        completion.pendingOffer = PendingFeedOffer(now: now.addingTimeInterval(-121))
        XCTAssertEqual(completion.answer(to: "yes"), .cancelled)
    }

    func testOfferTraceContainsIdentityAndTransitionWithoutTranscript() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = VoiceDiagnostics(directory: folder)
        let session = log.begin(engine: "test")
        var offer: PendingFeedOffer? = PendingFeedOffer()
        let id = offer!.id.uuidString
        _ = FullDuplexVoiceClient.resolveFeedOffer(&offer, transcript: "[inhale ]Yes", kind: "inbox", diagnostics: session)
        let trace = String(decoding: try await log.snapshot(), as: UTF8.self)
        XCTAssertTrue(trace.contains(id))
        XCTAssertTrue(trace.contains("queue_step_requested"))
        XCTAssertFalse(trace.contains("inhale"))
    }
}
