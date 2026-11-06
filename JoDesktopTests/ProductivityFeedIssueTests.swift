import FactoryKit
import Foundation
import XCTest
@testable import CodenameJo

@MainActor
final class ProductivityFeedIssueTests: XCTestCase {
    func testInformationAndFeedbackDoNotStartActionRecovery() {
        for text in ["Um, what's his email?", "What does archive mean?", "What is next?", "Can you tell me his email?", "save a command to archive", "I have feedback: archive did not work", "yeah", "don't archive this"] {
            XCTAssertFalse(LiveRequestRecovery.requiresQueueAction(text), text)
        }
        for text in ["Archive this", "please delete it", "can you archive this", "next"] {
            XCTAssertTrue(LiveRequestRecovery.requiresQueueAction(text), text)
        }
    }

    func testBackgroundResultCannotRetargetConfirmedMailOrAccount() {
        XCTAssertNotNil(LiveWriteTarget.refusal(tool: "archive_message", arguments: #"{"message_id":"old-invitation","account":"a@example.test"}"#, messageID: "booking", account: "a@example.test"))
        XCTAssertNotNil(LiveWriteTarget.refusal(tool: "gmail_label_message", arguments: #"{"message_id":"booking","account":"other@example.test"}"#, messageID: "booking", account: "a@example.test"))
        XCTAssertNil(LiveWriteTarget.refusal(tool: "archive_message", arguments: #"{"message_id":"booking","account":"a@example.test"}"#, messageID: "booking", account: "a@example.test"))
    }

    func testCalendarOffsetsUseEventDateAcrossDST() throws {
        let pacific = try CalendarWriteTiming.zone("America/Los_Angeles")
        XCTAssertThrowsError(try CalendarWriteTiming.validate("2026-11-02T12:00:00-07:00", zone: pacific))
        XCTAssertNoThrow(try CalendarWriteTiming.validate("2026-11-02T12:00:00-08:00", zone: pacific))
        XCTAssertThrowsError(try CalendarWriteTiming.validate("2026-03-08T02:30:00-08:00", zone: pacific))
        XCTAssertNoThrow(try CalendarWriteTiming.validate("2026-11-01T01:30:00-07:00", zone: pacific))
        XCTAssertNoThrow(try CalendarWriteTiming.validate("2026-11-01T01:30:00-08:00", zone: pacific))
        XCTAssertNoThrow(try CalendarWriteTiming.validate("2026-11-02T12:00:00-05:00", zone: CalendarWriteTiming.zone("America/New_York")))
    }

    func testInvitationUIDBeatsDisplayTitleAndCreateIdentityIsStable() {
        XCTAssertTrue(CalendarTools.matchesCreation(["iCalUID": "invite-1", "summary": "Different title"], ["ical_uid": "invite-1", "summary": "Conversation title"]))
        XCTAssertFalse(CalendarTools.matchesCreation(["iCalUID": "invite-2"], ["ical_uid": "invite-1"]))
        let a = CalendarTools.createIdentity(account: "a@example.test", title: "Project Review", start: "2026-11-02T12:00:00-08:00", end: "2026-11-02T13:00:00-08:00", attendees: ["b@example.test", "c@example.test"])
        let b = CalendarTools.createIdentity(account: "A@example.test", title: "project review", start: "2026-11-02T15:00:00-05:00", end: "2026-11-02T16:00:00-05:00", attendees: ["c@example.test", "b@example.test"])
        XCTAssertEqual(a, b)
    }

    func testConfirmedWriteAndForegroundContinuationAreSeparate() {
        let queue = #"{"completed":false,"remaining_work":"foreground_queue","report":"Archived but cannot advance"}"#
        XCTAssertTrue(DispatchWorker.actionResult(queue, writeFailed: false, writeSucceeded: true).ok)
        XCTAssertFalse(DispatchWorker.actionResult(queue, writeFailed: true, writeSucceeded: true).ok)
        XCTAssertFalse(DispatchWorker.actionResult(queue, writeFailed: false).ok)
        XCTAssertFalse(DispatchWorker.actionResult(#"{"completed":false,"remaining_work":"action","report":"Label failed"}"#, writeFailed: true, writeSucceeded: true).ok)
    }

    func testTurnFragmentsUpsertAndOutcomesDoNotInventSuccess() {
        var transcript = TurnTranscript()
        XCTAssertEqual(transcript.finish(item: "one", text: "First sentence."), "First sentence.")
        XCTAssertEqual(transcript.finish(item: "two", text: "Second sentence."), "First sentence. Second sentence.")
        XCTAssertEqual(transcript.finish(item: "two", text: "Second sentence."), "First sentence. Second sentence.")
        var success = TurnStep(tool: "label_message"); success.endedAt = Date()
        var failure = TurnStep(tool: "archive_message"); failure.endedAt = Date(); failure.failed = true
        XCTAssertEqual(CommandRecord.outcome(steps: [], interrupted: false), .conversational)
        XCTAssertEqual(CommandRecord.outcome(steps: [success], interrupted: false), .success)
        XCTAssertEqual(CommandRecord.outcome(steps: [failure], interrupted: false), .failed)
        XCTAssertEqual(CommandRecord.outcome(steps: [success, failure], interrupted: false), .partial)
        XCTAssertEqual(CommandRecord.outcome(steps: [TurnStep(tool: "archive")], interrupted: false), .unknown)
        XCTAssertEqual(CommandRecord.outcome(steps: [success], interrupted: true), .cancelled)
    }

    func testPausedInputAndAssistantSpeechRemainOneLogicalExchange() async throws {
        var inputs: [String] = [], replies: [String] = []
        let adapter = LiveSessionAdapter(wire: { _ in }, emit: {
            if case .liveInputFinished(let text) = $0 { inputs.append(text) }
            if case .event(.assistantTranscriptDone(_, let text)) = $0 { replies.append(text) }
        })
        func event(_ value: [String: Any]) throws { adapter.receive(try JSONSerialization.data(withJSONObject: value)) }
        try event(["type": "session.started"])
        try event(["type": "session.input_transcript.delta", "delta": "What is", "start_ms": 0, "end_ms": 300])
        try await Task.sleep(for: .milliseconds(1150))
        try event(["type": "session.input_transcript.delta", "delta": " his email?", "start_ms": 1800, "end_ms": 2200])
        try await Task.sleep(for: .milliseconds(1150))
        XCTAssertEqual(inputs.last, "What is his email?")
        try event(["type": "session.output_transcript.delta", "delta": "His email is ", "start_ms": 2500, "end_ms": 2700])
        try event(["type": "session.output_transcript.delta", "delta": "on the contact card.", "start_ms": 4400, "end_ms": 4700])
        adapter.close()
        XCTAssertEqual(replies, ["His email is on the contact card."])
    }

    func testDefaultExportContainsCorrelationButContentNeedsExplicitChoice() throws {
        let turn = UUID(), job = UUID()
        let record = CommandRecord(id: turn, commandText: "private user words", responseText: "private email body", status: .partial)
        let conversation = UUID()
        let work = DispatchJob(id: job, task: "private job task", state: "partial", result: "private job result", conversationId: conversation, turnId: turn.uuidString,
            receipts: [.init(callId: "call-1", tool: "archive_message", outcome: "success")])
        let safe = String(decoding: try SessionExport.append(records: [record], jobs: [work], to: Data(), includeContent: false), as: UTF8.self)
        XCTAssertFalse(safe.contains("private"))
        XCTAssertTrue(safe.contains(turn.uuidString))
        XCTAssertTrue(safe.contains(job.uuidString))
        XCTAssertTrue(safe.contains(conversation.uuidString))
        XCTAssertTrue(safe.contains("call-1"))
        XCTAssertTrue(safe.contains("partial"))
        let full = String(decoding: try SessionExport.append(records: [record], jobs: [work], to: Data(), includeContent: true), as: UTF8.self)
        XCTAssertTrue(full.contains("private user words"))
        XCTAssertTrue(full.contains("private job result"))
    }

    func testLiveDiagnosticsMapNestedFailureAndRemainUserScoped() async throws {
        let fields = try XCTUnwrap(VoiceDiagnostics.protocolFields(["type": "response.event", "event": ["type": "response.done", "response": ["id": "r1", "status": "failed", "status_details": ["error": ["code": "rate_limit", "message": "private secret"]]]]]))
        XCTAssertEqual(fields["provider_code"], "rate_limit")
        XCTAssertFalse(fields.values.contains("private secret"))
        XCTAssertNil(VoiceDiagnostics.protocolFields(["type": "session.input_transcript.delta", "delta": "private words"]))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = VoiceDiagnostics(directory: folder)
        let a = log.begin(engine: "live", userID: "a")
        let b = log.begin(engine: "live", userID: "b")
        a.record(.toolFinished, ["call_id": "call-a", "target_hash": a.target("email-id"), "outcome": "failed"])
        b.record(.toolFinished, ["call_id": "call-b"])
        let export = String(decoding: try await log.snapshot(userID: "a"), as: UTF8.self)
        XCTAssertTrue(export.contains("call-a"))
        XCTAssertFalse(export.contains("call-b"))
        XCTAssertFalse(export.contains("email-id"))
        XCTAssertNotEqual(a.target("email-id"), b.target("email-id"))
    }
}
