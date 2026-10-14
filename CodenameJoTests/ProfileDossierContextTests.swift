import Foundation
import XCTest
@testable import CodenameJo

final class ProfileDossierContextTests: XCTestCase {
    func testMissingDossierClearsTheEarlierOneInsteadOfReusingIt() throws {
        let text = ProfileDossierContext.transition(profileId: "personal", dossier: nil)
        XCTAssertTrue(text.contains("Earlier profile dossier context is inactive"))
        XCTAssertTrue(text.contains("No active dossier context"))
    }

    func testWrongProfileResultCannotBeInstalled() {
        let old = ProfileDossierContext(profileId: "work", overview: "Work-only facts", version: 2)
        let text = ProfileDossierContext.transition(profileId: "personal", dossier: old)
        XCTAssertFalse(text.contains("Work-only facts"))
        XCTAssertTrue(text.contains("No active dossier context"))
    }

    @MainActor
    func testProfileTransitionDeliversSameReferenceToBothLiveConsumersWithoutSessionUpdate() throws {
        var sent: [[String: Any]] = []
        let adapter = LiveSessionAdapter(wire: { sent.append($0) }, emit: { _ in })
        adapter.receive(try JSONSerialization.data(withJSONObject: ["type": "session.started"]))
        sent.removeAll()
        let dossier = ProfileDossierContext(profileId: "work", overview: "Prefers concise answers.", version: 2)
        let text = ProfileDossierContext.transition(profileId: "work", dossier: dossier)
        adapter.outbound([
            "type": "conversation.item.create", "speaker_brief": text, "await_context_ack": false,
            "item": ["type": "message", "role": "system",
                     "content": [["type": "input_text", "text": text]]],
        ])
        let backend = try XCTUnwrap(sent.first { $0["type"] as? String == "response.item.create" })
        XCTAssertEqual((backend["item"] as? [String: Any])?["content"] as? String, text)
        let speaker = sent.filter { $0["type"] as? String == "session.thinking.append" }
            .compactMap { $0["content"] as? String }.joined()
        XCTAssertEqual(speaker, text)
        XCTAssertFalse(sent.contains { $0["type"] as? String == "session.update" })
    }

    @MainActor
    func testOptionalDossierDoesNotGateSpeechButOrdinaryContextStillDoes() throws {
        for optional in [true, false] {
            var sent: [[String: Any]] = []
            let adapter = LiveSessionAdapter(wire: { sent.append($0) }, emit: { _ in })
            adapter.receive(try JSONSerialization.data(withJSONObject: ["type": "session.started"]))
            for event in sent where event["type"] as? String == "session.instructions.append" {
                adapter.receive(try JSONSerialization.data(withJSONObject: [
                    "type": "session.instructions.appended", "client_event_id": try XCTUnwrap(event["event_id"]),
                ]))
            }
            sent.removeAll()
            let text = ProfileDossierContext.transition(profileId: "personal", dossier: nil)
            var payload: [String: Any] = [
                "type": "conversation.item.create", "speaker_brief": text,
                "item": ["type": "message", "role": "system",
                         "content": [["type": "input_text", "text": text]]],
            ]
            if optional { payload["await_context_ack"] = false }
            adapter.outbound(payload)
            adapter.outbound(["type": "response.create"])
            XCTAssertEqual(sent.contains { $0["type"] as? String == "session.commentary.append" }, optional,
                           "Only optional dossier context may proceed without its acknowledgement")
            XCTAssertFalse(sent.contains { $0["await_context_ack"] != nil }, "Internal flags must not reach the wire")
        }
    }

}
