import Combine
import Foundation
import XCTest
@testable import CodenameJo

@MainActor
final class SessionHistoryReplayTests: XCTestCase {
    func testUnansweredFeedbackAndPartialTranscriptPersistBeforeReply() async throws {
        let service = RealtimeService()
        let client = FullDuplexVoiceClient()
        service.bindLiveHistory(client)
        client.handle(.liveUserActivity)
        let id = client.historyTurnID
        client.handle(.liveInputText("Feedback: the selected email"))
        XCTAssertEqual(service.lastCompletedTurn?.id, id)
        XCTAssertEqual(service.lastCompletedTurn?.status, .pending)
        client.handle(.liveInputFinished("Feedback: the selected email"))
        client.handle(.liveInputText("Feedback: the selected email changes while I am talking."))
        client.checkpointHistory()
        let record = try XCTUnwrap(service.lastCompletedTurn)
        XCTAssertEqual(record.id, id)
        XCTAssertEqual(record.commandText, "Feedback: the selected email changes while I am talking.")
        XCTAssertEqual(record.responseText, "")
        XCTAssertEqual(record.status, .pending)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let context = LocalContextStore(url: folder)
        defer { try? context.dbPool?.close(); try? FileManager.default.removeItem(at: folder) }
        let store = TurnStore(database: context.dbPool)
        try await store.save(.init(record, userId: "fixture:work"))
        let saved = try await store.history(owner: "fixture:work")
        XCTAssertEqual(saved.map(\.commandText), [record.commandText])
    }

    func testFragmentsAndLateCompletionKeepOriginalTurnAndTools() {
        let service = RealtimeService()
        let client = FullDuplexVoiceClient()
        service.bindLiveHistory(client)
        var rows: [UUID: CommandRecord] = [:]
        let subscription = service.$lastCompletedTurn.compactMap { $0 }.sink { rows[$0.id] = $0 }
        defer { subscription.cancel() }
        client.handle(.liveUserActivity)
        let original = client.historyTurnID
        client.handle(.liveInputText("Find my meeting"))
        var step = TurnStep(tool: "calendar_list")
        step.endedAt = Date()
        step.failed = true
        service.turnSteps = [step]
        client.handle(.liveInputFinished("Find my meeting tomorrow"))
        client.handle(.event(.assistantTranscriptDelta(itemId: "reply-a", delta: "I couldn't", spoken: true)))
        client.emitFinalTranscript()
        XCTAssertEqual(rows[original]?.status, .failed)
        client.handle(.liveUserActivity)
        service.turnSteps = []
        let next = client.historyTurnID
        client.handle(.liveInputText("Archive it now"))
        client.handle(.event(.assistantTranscriptDelta(itemId: "reply-a", delta: " find that meeting.", spoken: true)))
        client.emitFinalTranscript()
        client.emitFinalTranscript()
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[original]?.commandText, "Find my meeting tomorrow")
        XCTAssertEqual(rows[original]?.responseText, "I couldn't find that meeting.")
        XCTAssertEqual(rows[original]?.toolSteps?.map(\.tool), ["calendar_list"])
        XCTAssertEqual(rows[original]?.status, .failed)
        XCTAssertEqual(rows[next]?.responseText, "")
        XCTAssertNil(rows[next]?.toolSteps)
    }

    func testBackgroundReplyRetainsOriginWhenNewUserInterrupts() {
        let service = RealtimeService()
        let client = FullDuplexVoiceClient()
        service.bindLiveHistory(client)
        let original = UUID()
        client.historyTurnID = original
        client.historyUserText = "Research the meeting"
        client.checkpointHistory()
        client.isBackgroundHistory = true
        client.historyJobOutcomes[original] = .partial
        client.handle(.event(.assistantTranscriptDelta(itemId: "background", delta: "The meeting", spoken: true)))
        client.handle(.liveUserActivity)
        client.handle(.liveInputText("Skip this email"))
        client.handle(.event(.assistantTranscriptDone(itemId: "background", transcript: "The meeting time could not be confirmed.")))
        client.emitFinalTranscript()
        XCTAssertEqual(service.lastCompletedTurn?.id, original)
        XCTAssertEqual(service.lastCompletedTurn?.commandText, "Research the meeting")
        XCTAssertEqual(service.lastCompletedTurn?.status, .partial)
        XCTAssertEqual(service.lastCompletedTurn?.responseText, "The meeting time could not be confirmed.")
    }
}
