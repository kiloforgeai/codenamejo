import CryptoKit
import Foundation
import XCTest
@testable import CodenameJo

final class AppCoreContractTests: XCTestCase {
    func testBundledToolContractsRemainStableAcrossAccountConfigurations() throws {
        let accounts: [LiveSessionSetup.Accounts] = [
            .init(),
            .init(inboxes: ["work@example.test", "personal@example.test"],
                  calendars: ["work@example.test"], unread: ["personal@example.test"])
        ]
        let catalogs = accounts.map { accounts in
            LiveSessionSetup.Catalog.bundled.tools.mapValues { $0(accounts) }
        }
        let data = try JSONSerialization.data(withJSONObject: catalogs, options: [.sortedKeys])
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, "0e337a3c94437291b52c9e0effa210494974db452b3c121bed6af737a27ce77d",
                       "Tool contract changes require deliberate review, including account-scoped wording")
    }

    func testToolArgumentsPreserveAbsentFalseEmptyAndMalformedValues() throws {
        let arguments = ToolArguments(#"{"name":"  keep spaces  ","empty":"","enabled":false,"count":"3","nothing":null,"actions":[{"tool":"summarize","detail":"Keep this"},{"detail":"invalid"},{"tool":"search_context"}]}"#)
        XCTAssertEqual(arguments.string("name"), "  keep spaces  ")
        XCTAssertNil(arguments.string("empty"))
        XCTAssertNil(arguments.string("nothing"))
        XCTAssertNil(arguments.string("missing"))
        XCTAssertEqual(arguments.bool("enabled"), false)
        XCTAssertNil(arguments.bool("missing"))
        XCTAssertEqual(arguments.integer("count"), 3)
        XCTAssertEqual(arguments.actions.map(\.tool), ["summarize", "search_context"])
        XCTAssertEqual(arguments.actions.map(\.detail), ["Keep this", ""])
        let replaced = ToolArguments(arguments.replacingString("name", with: "new"))
        XCTAssertEqual(replaced.string("name"), "new")
        XCTAssertEqual(replaced.actions, arguments.actions)
        XCTAssertEqual(replaced.bool("enabled"), false)
        for malformed in ["invalid", "[]", "null"] {
            let parsed = ToolArguments(malformed)
            XCTAssertNil(parsed.string("name"))
            XCTAssertNil(parsed.integer("count"))
            XCTAssertTrue(parsed.actions.isEmpty)
            XCTAssertEqual(parsed.replacingString("name", with: "new"), malformed)
        }
    }

    func testHistoryMergesReplyFragmentsWithoutLosingEarlierEvidence() {
        var history = TurnHistory()
        let id = UUID(), conversation = UUID(), issued = Date(timeIntervalSince1970: 100)
        let first = CommandRecord(id: id, commandText: "Find the meeting", responseText: "First part",
            status: .partial, durationSeconds: 2, issuedAt: issued, conversationId: conversation,
            toolSteps: [.init(tool: "search_calendar", milliseconds: 20, outcome: "failed")],
            latency: .init(toFirstAudioMs: 80), brainSteps: [.init(ms: 10)])
        _ = history.complete(first)
        let merged = history.complete(.init(id: id, commandText: first.commandText, responseText: "Complete reply",
            status: .partial, durationSeconds: 3, conversationId: conversation, brainSteps: [.init(ms: 30)]))
        XCTAssertEqual(merged.durationSeconds, 5)
        XCTAssertEqual(merged.issuedAt, issued)
        XCTAssertEqual(merged.toolSteps, first.toolSteps)
        XCTAssertEqual(merged.latency, first.latency)
        XCTAssertEqual(merged.brainSteps?.map(\.ms), [10, 30])
        XCTAssertEqual(merged.responseText, "Complete reply")
        let unrelated = history.complete(.init(commandText: "A new question"))
        XCTAssertNil(unrelated.toolSteps)
        XCTAssertNil(unrelated.latency)
        XCTAssertNil(unrelated.brainSteps)
    }

    func testLateBackgroundHistoryReplyKeepsItsOriginAndOnlyUpdatesDispatchOutcome() throws {
        var history = TurnHistory()
        let id = UUID(), conversation = UUID()
        var failedRead = TurnStep(tool: "search_recent")
        failedRead.endedAt = Date()
        failedRead.failed = true
        failedRead.serverMilliseconds = 0
        let steps = [failedRead, TurnStep(tool: "dispatch")]
        let first = try XCTUnwrap(history.checkpoint(id: id, text: "Research this", conversationID: conversation, steps: steps))
        XCTAssertNil(first.toolSteps?.first?.milliseconds)
        XCTAssertNil(history.checkpoint(id: id, text: "Research this", conversationID: conversation, steps: steps))
        _ = history.checkpoint(id: UUID(), text: "Next question", conversationID: UUID(), steps: [])
        let reply = history.reply(.init(origin: .init(id: id, userText: "Research this", background: true), text: "Partial result"),
                                  conversationID: UUID(), status: .partial)
        XCTAssertEqual(reply.conversationId, conversation)
        XCTAssertEqual(reply.commandText, "Research this")
        XCTAssertEqual(reply.toolSteps?.map(\.outcome), ["failed", "partial"])
        XCTAssertEqual(reply.status, .partial)
    }

    func testExistingSavedFeedProgressDecodesAfterStateExtraction() throws {
        let json = #"{"day":"2026-10-28","completed":["calendar"],"page":{"band":"high","score":8,"beforeID":"cursor","preparedAt":0,"stage":{"items":[],"grouping":false,"topicGrouping":false,"adopted":false,"position":0,"ordinalOffset":12,"more":true,"total":30,"mailboxUnreadAtStart":4,"scope":"important","scopeUnsaid":false,"scopePlan":["important","unread","all"],"stalled":false}}}"#
        let saved = try JSONDecoder().decode(TriageFeedSections.Progress.self, from: Data(json.utf8))
        XCTAssertEqual(saved.page?.stage.ordinalOffset, 12)
        XCTAssertEqual(saved.page?.stage.scopePlan, [.important, .unread, .all])
        XCTAssertEqual(saved.completed, ["calendar"])
        let encoded = try JSONEncoder().encode(saved)
        let roundTrip = try JSONSerialization.jsonObject(with: encoded) as? NSDictionary
        let original = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? NSDictionary
        XCTAssertEqual(roundTrip, original)
    }

    func testCancelingPreparedSectionsKeepsTheCurrentWalkAndInvalidatesPendingWork() async {
        let first = FeedSection(kind: .important, account: "work@example.test")
        let next = FeedSection(kind: .remaining, account: "work@example.test")
        var disabled = FeedSection(kind: .calendar)
        disabled.enabled = false
        var state = TriageFeedSections()
        state.plan = [first, disabled, next]
        state.active = first
        state.profileID = "work"
        state.progressLoaded = true
        state.completed = [disabled.id]
        let page = TriageFeedSections.Prepared(stage: .init(items: [], grouping: false,
            topicGrouping: false, adopted: false, position: 0, ordinalOffset: 0, before: nil,
            more: true, total: 30, mailboxUnreadAtStart: 4, scope: .all, scopeUnsaid: false,
            scopePlan: [.all], stalled: false), band: nil, score: nil, beforeID: nil, preparedAt: Date())
        state.prepared[next.id] = page
        let oldToken = state.preparationID
        let task = Task { try? await Task.sleep(for: .seconds(30)) }
        state.preparation = Task { _ = await task.value }
        let load = Task { _ = await task.value; return page }
        state.loads[next.id] = load
        let preparation = state.preparation
        state.cancelPreparation()
        task.cancel()
        XCTAssertNotEqual(state.preparationID, oldToken)
        XCTAssertEqual(preparation?.isCancelled, true)
        XCTAssertTrue(load.isCancelled)
        XCTAssertNil(state.preparation)
        XCTAssertTrue(state.prepared.isEmpty)
        XCTAssertTrue(state.loads.isEmpty)
        XCTAssertEqual(state.active, first)
        XCTAssertEqual(state.profileID, "work")
        XCTAssertTrue(state.progressLoaded)
        XCTAssertEqual(state.completed, [disabled.id])
        XCTAssertEqual(state.upcoming, [next])
        _ = await preparation?.value
        _ = await load.value
    }
}
