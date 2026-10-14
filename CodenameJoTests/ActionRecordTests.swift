import XCTest
@testable import CodenameJo

final class ActionRecordTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_783_512_000)
    private let link = "https://example.test/messages/message-7"

    private func decode(_ fields: [String: Any] = [:]) throws -> ActionRecord {
        var json: [String: Any] = [
            "id": "11111111-1111-1111-1111-111111111111",
            "tool": "archive_message", "connector": "gmail",
            "account": "owner@example.test", "summary": "Archiving invoice", "state": "pending"
        ]
        json.merge(fields) { _, replacement in replacement }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ActionRecord.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testBrokerFieldsDecodeWithoutLosingAccountOrEvidence() throws {
        let record = try decode([
            "state": "failed", "detail": "Mailbox permission denied",
            "item_id": "message-7", "thread_id": "thread-3", "url": link,
            "conversation_id": "call-2", "started_at": "2026-07-08T12:00:00Z",
            "completed_at": "2026-07-08T12:01:00Z", "retry_until": "2026-07-08T13:00:00Z"
        ])
        XCTAssertEqual(record.id, UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        XCTAssertEqual(record.tool, "archive_message")
        XCTAssertEqual(record.connector, "gmail")
        XCTAssertEqual(record.account, "owner@example.test")
        XCTAssertEqual(record.summary, "Archiving invoice")
        XCTAssertEqual(record.detail, "Mailbox permission denied")
        XCTAssertEqual(record.itemId, "message-7")
        XCTAssertEqual(record.threadId, "thread-3")
        XCTAssertEqual(record.conversationId, "call-2")
        XCTAssertEqual(record.url, link)
        XCTAssertEqual(record.startedAt, start)
        XCTAssertEqual(record.completedAt, start.addingTimeInterval(60))
        XCTAssertEqual(record.retryUntil, start.addingTimeInterval(3_600))
        XCTAssertTrue(record.didFail)
        XCTAssertFalse(record.isDone, "A completion timestamp does not establish success")
        XCTAssertNil(record.proofURL)
    }

    func testOlderAndExplicitlyNullOptionalFieldsRemainReadable() throws {
        for fields: [String: Any] in [[:], [
            "detail": NSNull(), "item_id": NSNull(), "thread_id": NSNull(),
            "url": NSNull(), "conversation_id": NSNull(), "started_at": NSNull(),
            "completed_at": NSNull(), "retry_until": NSNull()
        ]] {
            let record = try decode(fields)
            XCTAssertNil(record.detail)
            XCTAssertNil(record.itemId)
            XCTAssertNil(record.threadId)
            XCTAssertNil(record.url)
            XCTAssertNil(record.conversationId)
            XCTAssertNil(record.startedAt)
            XCTAssertNil(record.completedAt)
            XCTAssertNil(record.retryUntil)
            XCTAssertTrue(record.isAbandoned(asOf: start))
            XCTAssertFalse(record.didFail, "Missing timing leaves the outcome unknown")
        }
    }

    func testMalformedIdentityStateAndDatesThrowDecodingErrors() {
        for fields: [String: Any] in [
            ["id": "not-a-uuid"], ["account": NSNull()], ["state": 42],
            ["started_at": "yesterday"], ["completed_at": false], ["retry_until": "later"]
        ] {
            XCTAssertThrowsError(try decode(fields), "Malformed fields: \(fields)") { error in
                XCTAssertTrue(error is DecodingError)
            }
        }
    }

    func testSingleRequestRemainsPendingThroughSixtySeconds() throws {
        var record = try decode()
        record.startedAt = start
        for elapsed in [-1.0, 0, 59.999, 60] {
            let now = start.addingTimeInterval(elapsed)
            XCTAssertFalse(record.hasSettled(asOf: now), "Elapsed: \(elapsed)")
            XCTAssertFalse(record.isAbandoned(asOf: now), "Elapsed: \(elapsed)")
        }
        XCTAssertTrue(record.hasSettled(asOf: start.addingTimeInterval(60.001)))
        XCTAssertTrue(record.isAbandoned(asOf: start.addingTimeInterval(60.001)))
        XCTAssertTrue(record.isPending, "Age classifies uncertainty without rewriting broker state")
        XCTAssertFalse(record.didFail)
        XCTAssertFalse(record.isDone)
    }

    func testDurableRetryAllowsTwoMinuteGraceEvenWithoutStartTime() throws {
        let deadline = start.addingTimeInterval(3_600)
        for startedAt in [Optional(start), nil] {
            var record = try decode()
            record.startedAt = startedAt
            record.retryUntil = deadline
            for offset in [-1.0, 0, 119.999, 120] {
                let now = deadline.addingTimeInterval(offset)
                XCTAssertFalse(record.hasSettled(asOf: now), "Deadline offset: \(offset)")
                XCTAssertFalse(record.isAbandoned(asOf: now), "Deadline offset: \(offset)")
            }
            XCTAssertTrue(record.hasSettled(asOf: deadline.addingTimeInterval(120.001)))
            XCTAssertTrue(record.isAbandoned(asOf: deadline.addingTimeInterval(120.001)))
            XCTAssertFalse(record.didFail)
        }
    }

    func testTerminalStatesOverrideRetryWindowAndNeverBecomeAbandoned() throws {
        for state in ["done", "failed"] {
            var record = try decode(["state": state])
            record.startedAt = start
            record.retryUntil = start.addingTimeInterval(3_600)
            for elapsed in [0.0, 60, 10_000] {
                let now = start.addingTimeInterval(elapsed)
                XCTAssertTrue(record.hasSettled(asOf: now), state)
                XCTAssertFalse(record.isAbandoned(asOf: now), state)
            }
            XCTAssertFalse(record.isPending)
            XCTAssertEqual(record.isDone, state == "done")
            XCTAssertEqual(record.didFail, state == "failed")
        }
    }

    func testOnlyConfirmedSuccessExposesProofWhenPendingWriteSettles() throws {
        let pending = try decode(["url": link])
        XCTAssertNil(pending.proofURL)
        var successful = pending
        successful.state = "done"
        XCTAssertEqual(successful.proofURL?.absoluteString, link)
        var failed = pending
        failed.state = "failed"
        failed.completedAt = start
        failed.detail = "Mailbox permission denied"
        XCTAssertNil(failed.proofURL)
        XCTAssertTrue(failed.didFail)
        XCTAssertFalse(failed.isDone)
        successful.url = nil
        XCTAssertNil(successful.proofURL, "Success need not have a vendor deep link")
        successful.url = "https://["
        XCTAssertNil(successful.proofURL, "Malformed links must not become tappable proof")
    }

    func testFutureBrokerStateRoundTripsWithoutBecomingSuccessOrFailure() throws {
        let record = try decode(["state": "awaiting_provider", "url": link])
        XCTAssertFalse(record.isPending)
        XCTAssertFalse(record.isDone)
        XCTAssertFalse(record.didFail)
        XCTAssertFalse(record.isAbandoned(asOf: start))
        XCTAssertNil(record.proofURL)
        let encoded = try JSONEncoder().encode(record)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(json["state"] as? String, "awaiting_provider")
        XCTAssertEqual(json["account"] as? String, "owner@example.test")
        let restored = try JSONDecoder().decode(ActionRecord.self, from: encoded)
        XCTAssertEqual(restored.state, "awaiting_provider")
        XCTAssertNil(restored.proofURL)
    }
}
