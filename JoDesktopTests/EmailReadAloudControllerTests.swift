import XCTest
@testable import CodenameJo

@MainActor
final class EmailReadAloudControllerTests: XCTestCase {
    private func value() -> EmailReadAloud {
        .init(selection: .init(account: "fixture@example.test", messageID: "A"),
            threadID: "thread-A", profileID: "profile", ownerID: "owner")
    }
    @MainActor private final class Harness {
        var source = String(repeating: "First and middle marker. ", count: 80) + "FINAL MARKER."
        var failFetch = false
        var current = true
        var fetched: [MailSelection] = []
        var sent: [String] = []
        var failures: [String] = []
        var events: [String] = []
        var gates: [() -> Bool] = []
        var held: CheckedContinuation<EmailReadAloudController.Source, Error>?
        var holdFetch = false
        lazy var controller = EmailReadAloudController(fetch: { [unowned self] value in
            fetched.append(value.selection)
            if holdFetch { return try await withCheckedThrowingContinuation { held = $0 } }
            if failFetch { throw URLError(.timedOut) }
            return (source, false)
        }, isCurrent: { [unowned self] _ in current }, speak: { [unowned self] text, gate in
            sent.append(text); gates.append(gate)
        }, stopSpeech: {}, failure: { [unowned self] in failures.append($0) },
        trace: { [unowned self] _, event in events.append(event) })
    }
    private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<300 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Expected reading transition")
    }

    func testControllerDeliversEveryPassageInOrderAndCompletesOnlyAfterAudio() async throws {
        let h = Harness(); defer { h.controller.cancel() }
        h.controller.start(value())
        try await wait { h.sent.count == 1 }
        var spoken: [String] = []
        while h.controller.reading?.phase != .completed {
            let chunk = try XCTUnwrap(h.sent.last)
            XCTAssertTrue(h.gates.last?() == true)
            h.controller.transcript(chunk)
            h.controller.audioStopped()
            XCTAssertNotEqual(h.controller.reading?.phase, .completed)
            h.controller.audioStarted(); h.controller.audioStopped()
            spoken.append(chunk)
        }
        XCTAssertEqual(spoken.joined(), h.source)
        XCTAssertEqual(h.fetched, [value().selection])
        XCTAssertEqual(h.events.filter { $0 == "completed" }.count, 1)
        XCTAssertTrue(h.failures.isEmpty)
        XCTAssertFalse(h.controller.ownsSpeech)
    }

    func testFailureThenYesRetryFetchesSameTargetAndDoesNotClaimRetrievalFromSpeech() async throws {
        let h = Harness(); defer { h.controller.cancel() }
        h.failFetch = true
        h.controller.start(value())
        try await wait { h.failures.count == 1 }
        XCTAssertEqual(EmailReadAloud.intent("Yes", retryPending: h.controller.reading?.retryPending == true), .retry)
        XCTAssertTrue(h.sent.isEmpty)
        h.failFetch = false
        h.controller.resume()
        try await wait { !h.sent.isEmpty }
        XCTAssertEqual(h.fetched, [value().selection, value().selection])
        XCTAssertEqual(h.controller.reading?.cursor, 0)
    }

    func testPauseAndRetryRetainUnfinishedChunkAndInvalidateQueuedSpeech() async throws {
        let h = Harness(); defer { h.controller.cancel() }
        h.controller.start(value())
        try await wait { h.sent.count == 1 }
        h.controller.audioStarted(); h.controller.transcript(h.sent[0]); h.controller.audioStopped()
        XCTAssertEqual(h.sent.count, 2)
        let second = h.sent[1], gate = h.gates[1]
        h.controller.audioStarted(); h.controller.transcript(String(second.prefix(20)))
        h.controller.pause()
        XCTAssertFalse(gate())
        h.controller.audioStopped()
        XCTAssertEqual(h.controller.reading?.cursor, 1)
        h.controller.resume()
        XCTAssertEqual(h.sent.last, second)
        XCTAssertEqual(h.fetched.count, 1)
        h.controller.audioStarted(); h.controller.transcript("A summary rather than the requested words.")
        h.controller.audioStopped()
        XCTAssertEqual(h.controller.reading?.phase, .failed)
        XCTAssertEqual(h.controller.reading?.cursor, 1)
        XCTAssertFalse(h.events.contains("completed"))
    }

    func testLateFetchAfterCancelOrSelectionChangeCannotQueueSpeech() async throws {
        for cancel in [false, true] {
            let h = Harness(); h.holdFetch = true
            h.controller.start(value())
            try await wait { h.held != nil }
            if cancel { h.controller.cancel() } else { h.current = false }
            h.held?.resume(returning: (h.source, false)); h.held = nil
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertTrue(h.sent.isEmpty)
            XCTAssertFalse(h.events.contains("completed"))
            h.controller.cancel()
        }
    }

    func testPlaybackTimeoutDoesNotSkipTextAndCanRetryWithoutFetchingAgain() async throws {
        let h = Harness(); defer { h.controller.cancel() }
        h.controller.playbackBound = 0.03
        h.controller.start(value())
        try await wait { !h.failures.isEmpty }
        XCTAssertEqual(h.controller.reading?.cursor, 0)
        XCTAssertEqual(h.controller.reading?.phase, .failed)
        h.controller.playbackBound = 30
        h.controller.resume()
        XCTAssertEqual(h.sent.count, 2)
        XCTAssertEqual(h.sent[0], h.sent[1])
        XCTAssertEqual(h.fetched.count, 1)
    }
}
