import XCTest
@testable import CodenameJo

// coverage-target: CodenameJo/Models/ConversationRecord.swift

/// The row that says when a call started, when it ended and why. It is written twice per
/// call and read back by things that must not mistake a killed app for a live one, so the
/// end fields have to stay genuinely absent when there was no end, and a row written by an
/// older build has to keep decoding.
///
/// Dates go through `.iso8601`, which is what `BackendService`'s encoder writes.
final class ConversationRecordDecodingTests: XCTestCase {

    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    func testAFinishedCallSurvivesTheRoundTripWithItsReasonAndBuildStamp() throws {
        let started = Date(timeIntervalSince1970: 1_756_000_000)
        let record = ConversationRecord(
            id: UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301")!,
            startedAt: started,
            endedAt: started.addingTimeInterval(95),
            endedReason: ConversationRecord.Reason.closedByServer,
            appVersion: "1.4",
            build: "231",
            osVersion: "26.0.1")

        let decoded = try decoder().decode(
            ConversationRecord.self, from: try encoder().encode(record))

        XCTAssertEqual(decoded.id, record.id)
        XCTAssertEqual(decoded.startedAt, started)
        XCTAssertEqual(decoded.endedAt, started.addingTimeInterval(95))
        XCTAssertEqual(decoded.endedReason, "closed_by_server")
        XCTAssertEqual(decoded.appVersion, "1.4")
        XCTAssertEqual(decoded.build, "231")
        XCTAssertEqual(decoded.osVersion, "26.0.1")
    }

    /// A row written before the build stamp existed has none of those three keys. It must
    /// decode, and it must decode as *unknown* — the property defaults describe a row this
    /// process is writing, not one it is reading back.
    func testARowWrittenBeforeTheBuildStampStillDecodes() throws {
        let json = Data("""
        {"id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301",
         "startedAt":"2026-08-17T09:00:00Z",
         "endedAt":"2026-08-17T09:03:20Z",
         "endedReason":"user_ended"}
        """.utf8)

        let decoded = try decoder().decode(ConversationRecord.self, from: json)

        XCTAssertEqual(decoded.endedReason, "user_ended")
        XCTAssertEqual(decoded.endedAt?.timeIntervalSince(decoded.startedAt), 200)
        XCTAssertNil(decoded.appVersion)
        XCTAssertNil(decoded.build)
        XCTAssertNil(decoded.osVersion)
    }

    /// A live call has no end and no reason, and every reason is its own word — filing one
    /// end under another's name is the thing the vocabulary exists to prevent.
    func testALiveRowCarriesNoEndAndEveryReasonIsDistinct() throws {
        let json = Data("""
        {"id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301","startedAt":"2026-08-17T09:00:00Z"}
        """.utf8)

        let decoded = try decoder().decode(ConversationRecord.self, from: json)
        XCTAssertNil(decoded.endedAt)
        XCTAssertNil(decoded.endedReason)

        let reasons = [
            ConversationRecord.Reason.userEnded,
            ConversationRecord.Reason.backgroundTimeout,
            ConversationRecord.Reason.transportFailure,
            ConversationRecord.Reason.closedByServer,
            ConversationRecord.Reason.promptSwitchChanged,
            ConversationRecord.Reason.carPlayDisconnected,
            ConversationRecord.Reason.dialTimedOut,
        ]
        XCTAssertEqual(Set(reasons).count, reasons.count)
        XCTAssertTrue(reasons.allSatisfy { !$0.isEmpty && $0 == $0.lowercased() })
    }
}
