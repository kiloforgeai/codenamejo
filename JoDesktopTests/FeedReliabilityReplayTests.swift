import Foundation
import XCTest
@testable import CodenameJo

final class FeedReliabilityReplayTests: XCTestCase {
    func testLateJobOutcomeUpdatesOriginalTurnAndSurvivesLateTranscriptSave() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let context = LocalContextStore(url: folder)
        defer { try? context.dbPool?.close(); try? FileManager.default.removeItem(at: folder) }
        let store = TurnStore(database: context.dbPool)
        let original = CommandRecord(commandText: "Archive D", responseText: "Working on it", status: .unknown)
        let other = CommandRecord(commandText: "What is G?", responseText: "Here is G", status: .conversational)
        let job = UUID()
        try await store.save(.init(original, userId: "user:profile:work"))
        try await store.save(.init(other, userId: "user:profile:work"))
        try await store.recordJobOutcome(userID: "user:profile:work", turnID: original.id.uuidString, jobID: job, outcome: .success)
        try await store.save(.init(original, userId: "user:profile:work"))
        let history = try await store.history(owner: "user:profile:work")
        XCTAssertEqual(history.first { $0.id == original.id }?.status, .success)
        XCTAssertEqual(history.first { $0.id == other.id }?.status, .conversational)
        XCTAssertEqual(history.first { $0.id == original.id }?.commandText, "Archive D")
        let unrelated = try await store.history(owner: "user:profile:personal")
        XCTAssertTrue(unrelated.isEmpty)
    }

    func testJobOutcomeBeforeHistoryAndPartialMultistepOutcome() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let context = LocalContextStore(url: folder)
        defer { try? context.dbPool?.close(); try? FileManager.default.removeItem(at: folder) }
        let store = TurnStore(database: context.dbPool)
        let record = CommandRecord(commandText: "Label and archive", status: .unknown)
        try await store.recordJobOutcome(userID: "u", turnID: record.id.uuidString, jobID: UUID(), outcome: .partial)
        try await store.save(.init(record, userId: "u"))
        let history = try await store.history(owner: "u")
        XCTAssertEqual(history.first?.status, .partial)
        XCTAssertEqual(history.first?.toolSteps?.first?.outcome, "partial")
    }

}
