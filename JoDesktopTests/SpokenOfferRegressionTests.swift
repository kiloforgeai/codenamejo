import XCTest
@testable import CodenameJo

@MainActor
final class SpokenOfferRegressionTests: XCTestCase {
    func testExplicitLocalCommandRetryOwnsTheTurnBeforeBrainSettlement() async throws {
        var requests = 0, claimed = false
        var adapter: LiveSessionAdapter!
        adapter = LiveSessionAdapter(wire: { _ in }, emit: { signal in
            if case .liveInputFinished(let text) = signal, CommandRetryText.matches(text, keyword: "follow up") {
                claimed = adapter.beginFastAction(callId: "retry", action: nil, routed: true)
                adapter.resolveLocalInput(applicationResult: "The application is restoring the original failed command source.", allowPresentation: false)
            }
        })
        adapter.enableClientDelegation { _ in requests += 1; return ["output": []] }
        func receive(_ event: [String: Any]) throws { adapter.receive(try JSONSerialization.data(withJSONObject: event)) }
        try receive(["type": "session.started"])
        try receive(["type": "session.input_transcript.delta", "delta": "Run it again", "start_ms": 0, "end_ms": 100])
        try receive(["type": "session.delegation.created", "offset_ms": 100, "delegation": ["id": "retry-delegation", "target": "client"]])
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertTrue(claimed)
        XCTAssertEqual(requests, 0)
        XCTAssertTrue(adapter.canRestoreReturnedWork("retry"))
        XCTAssertFalse(adapter.canRestoreReturnedWork("unrelated"))
        XCTAssertFalse(adapter.beginFastAction(callId: "duplicate", action: nil, routed: true))
        adapter.close()
        XCTAssertFalse(adapter.canRestoreReturnedWork("retry"))
    }

    func testNaturalCleanupAndInboxOffersAreConsumedOnceWithoutAcceptingQualifications() {
        for text in ["Yeah, let's do some cleanup", "[inhale] Yeah, let’s do some cleanup.",
                     "yes, go through my inbox", "okay, let's go through the feed please"] {
            var offer = PendingFeedOffer()
            XCTAssertEqual(offer.resolve(text), .accepted, text)
            XCTAssertEqual(offer.resolve(text), .expired, "Duplicate finalization must not advance again")
        }
        for text in ["yes, but not now", "yeah, let's not do cleanup", "no cleanup please"] {
            XCTAssertEqual(FeedOfferAnswer.answer(to: text), .declined, text)
        }
        for text in ["yes, go through my inbox and archive everything", "yeah, let's do cleanup after lunch",
                     "yes, read this instead", "[unknown] let's do some cleanup"] {
            XCTAssertNil(FeedOfferAnswer.answer(to: text), text)
        }
    }

    func testLocallyAcceptedOfferDoesNotAlsoRunItsDelegatedQueueStep() async throws {
        var requests: [[String: Any]] = []
        var adapter: LiveSessionAdapter!
        adapter = LiveSessionAdapter(wire: { _ in }, emit: { signal in
            if case .liveInputFinished(let text) = signal, FeedOfferAnswer.answer(to: text) == .accepted {
                adapter.resolveLocalInput(applicationResult: "The application accepted cleanup and is loading the first item.")
            }
        })
        adapter.clientBrainState = { ("No email selected.", "work") }
        adapter.enableClientDelegation { body in requests.append(body); return ["output": []] }
        func receive(_ event: [String: Any]) throws { adapter.receive(try JSONSerialization.data(withJSONObject: event)) }
        try receive(["type": "session.started"])
        try receive(["type": "session.input_transcript.delta", "delta": "Yeah, let's do some cleanup", "start_ms": 0, "end_ms": 100])
        try receive(["type": "session.delegation.created", "offset_ms": 100, "delegation": ["id": "offer", "target": "client"]])
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertTrue(requests.isEmpty, "Local acceptance must consume the model's duplicate delegation")
        adapter.clientBrainState = { (#"{"item":{"id":"a","account":"owner"}}"#, "work") }
        adapter.outbound(["type": "conversation.item.create", "item": ["type": "message", "role": "system", "content": [["type": "input_text", "text": "First item is ready; present it."]]]])
        adapter.outbound(["type": "response.create"])
        try receive(["type": "session.delegation.created", "offset_ms": 100, "delegation": ["id": "present", "target": "client"]])
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while requests.isEmpty, .now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?["presentationOnly"] as? Bool, true)
        try receive(["type": "session.delegation.created", "offset_ms": 100, "delegation": ["id": "present", "target": "client"]])
        XCTAssertEqual(requests.count, 1)
        adapter.close()
    }

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
