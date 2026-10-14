import XCTest
@testable import CodenameJo

final class GmailWriteEffectTests: XCTestCase {
    func testRelayAndMCPPreserveOrderedPartialFailureEffects() throws {
        let raw: [String: Any] = ["account": "you@test", "scope": "thread", "threadId": "t", "messageIds": [],
                                  "messageIdsComplete": false, "operation": "modify", "removeLabelIds": ["INBOX"]]
        let relay: [String: Any] = ["output": "Archive failed after the first write", "ok": false, "effects": [raw, raw]]
        let direct = try XCTUnwrap(GmailWriteEffect.decodeEffects(in: relay))
        XCTAssertEqual(direct.count, 2)
        XCTAssertFalse(direct[0].messageIdsComplete)
        XCTAssertTrue(direct[0].removesFromInbox)
        let mcp: [String: Any] = ["content": [["type": "text", "text": "partial failure"]],
                                  "structuredContent": ["output": "partial failure", "effects": [raw, raw]]]
        let data = try JSONSerialization.data(withJSONObject: mcp)
        XCTAssertEqual(GmailWriteEffect.decodeEffects(in: ["output": String(decoding: data, as: UTF8.self)]), direct)
    }

    func testTransportFailurePreventsPrimaryCompletionWithoutDiscardingEffects() {
        XCTAssertTrue(GmailWriteEffect.hasFailure(in: ["error": ["message": "Gmail API call failed"], "effects": []]))
        XCTAssertTrue(GmailWriteEffect.hasFailure(in: ["output": "{\"isError\":true,\"effects\":[]}"]))
        XCTAssertFalse(GmailWriteEffect.hasFailure(in: ["output": "Saved", "error": NSNull()]))
    }

    func testMissingAndEmptyEffectsAreDifferent() {
        XCTAssertNil(GmailWriteEffect.decodeEffects(in: ["output": "Archived."]))
        XCTAssertEqual(GmailWriteEffect.decodeEffects(in: ["output": "Failed", "effects": []]), [])
        XCTAssertEqual(GmailWriteEffect.decodeEffects(in: ["effects": [["scope": "thread"]]]), [])
    }
}
