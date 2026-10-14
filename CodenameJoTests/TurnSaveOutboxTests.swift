import Foundation
import XCTest
@testable import CodenameJo

final class TurnSaveOutboxTests: XCTestCase {
    private func turn() -> CommandRecord {
        CommandRecord(commandText: "Remember my preference", responseText: "OK",
            serviceName: "Jo", serviceIcon: "sparkles", status: .success,
            durationSeconds: 1, conversationId: UUID())
    }

    func testPersistedTurnWaitsForItsOriginalOwnerAfterRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("outbox.json")
        let saves = TurnSaves()
        await saves.allow()
        let signedOut = TurnSaveOutbox(fileURL: file, automaticallyRetry: false, credentials: { _ in nil },
            saveTurn: { _, owner, _ in await saves.save(owner: owner) })
        await signedOut.enqueue(conversation: UUID(), owner: "alice", failedTurns: [turn()])
        let before = await saves.owners
        XCTAssertTrue(before.isEmpty)

        let restarted = TurnSaveOutbox(fileURL: file, automaticallyRetry: false,
            credentials: { $0 == "alice" ? "alice-session" : nil },
            saveTurn: { _, owner, _ in await saves.save(owner: owner) })
        await restarted.drain()
        await restarted.drain()
        let owners = await saves.owners
        XCTAssertEqual(owners, ["alice"])
        let pending = await restarted.pendingTurns
        XCTAssertEqual(pending, 0)
    }

    func testPurgingOwnerPreservesOtherOwner() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("outbox.json")
        let outbox = TurnSaveOutbox(fileURL: file, automaticallyRetry: false, credentials: { _ in nil })
        await outbox.enqueue(conversation: UUID(), owner: "bob", failedTurns: [turn()])
        await outbox.enqueue(conversation: UUID(), owner: "alice", failedTurns: [turn()])
        await outbox.purge(owner: "alice")
        let persisted = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(persisted.count, 1)
        XCTAssertTrue(persisted.keys.allSatisfy { $0.hasPrefix("bob:") })
    }

    func testFailedSaveStaysUntilARetrySucceeds() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let saves = TurnSaves()
        let outbox = TurnSaveOutbox(fileURL: directory.appendingPathComponent("outbox.json"), automaticallyRetry: false,
            credentials: { _ in "session" }, saveTurn: { _, owner, _ in await saves.save(owner: owner) })
        await outbox.enqueue(conversation: UUID(), owner: "alice", failedTurns: [turn()])
        let stillPending = await outbox.pendingTurns
        XCTAssertEqual(stillPending, 1)
        await saves.allow()
        await outbox.drain()
        let pending = await outbox.pendingTurns
        let owners = await saves.owners
        XCTAssertEqual(pending, 0)
        XCTAssertEqual(owners, ["alice", "alice"])
    }
}

private actor TurnSaves {
    var owners: [String] = []
    private var succeeds = false
    func allow() { succeeds = true }
    func save(owner: String) -> Bool {
        owners.append(owner)
        return succeeds
    }
}
