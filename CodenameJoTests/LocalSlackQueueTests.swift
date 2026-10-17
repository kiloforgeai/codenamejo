import XCTest
@testable import CodenameJo

final class LocalSlackQueueTests: XCTestCase {
    private func item(_ channel: String, withUser: String? = nil) -> SlackQueueSnapshot.Item {
        .init(teamId: "T1", teamName: "Acme", channelId: channel, withUserId: withUser,
              label: "#\(channel)", kind: withUser == nil ? "channel" : "dm", unread: 2, more: false,
              messages: [.init(from: "Sam", fromId: "U9", ts: "1.2", text: "hi", threadTs: nil, replies: nil)],
              why: "asks you something")
    }

    private func snapshot(_ items: [SlackQueueSnapshot.Item]) -> SlackQueueSnapshot {
        .init(workspaces: ["Acme"], total: items.count, items: items,
              report: .init(workspacesUnavailable: nil, unchecked: 0, unreachable: 0,
                            readStateUnknown: 0, dmsUnavailable: nil, markUnavailable: nil))
    }

    private func object(_ text: String) -> [String: Any] {
        let json = text.firstIndex(of: "{").map { String(text[$0...]) } ?? text
        return (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
    }

    func testReplyOnCurrentConversationAdvancesInlineAndEchoIsSuppressed() async {
        let queue = LocalSlackQueue()
        await queue.start(snapshot([item("C1"), item("C2")]))
        let now = Date()
        let advance = await queue.finish(tool: "slack_send_message", input: ["channel_id": "C1"],
                                         written: true, channel: "C1", markedRead: true, now: now)
        XCTAssertEqual(advance?.closed, false)
        XCTAssertTrue(advance?.text.contains("that was 1 of 2, 1 left") == true)
        let echo = await queue.step(direction: nil, restart: false, stop: false,
                                    now: now.addingTimeInterval(1))
        XCTAssertEqual(object(echo.text)["repeat"] as? Bool, true)
        XCTAssertEqual((object(echo.text)["item"] as? [String: Any])?["channel_id"] as? String, "C2")
    }

    func testWriteToAnotherConversationDoesNotMoveTheCursor() async {
        let queue = LocalSlackQueue()
        await queue.start(snapshot([item("C1"), item("C2")]))
        let advance = await queue.finish(tool: "slack_send_message", input: ["channel_id": "C9"],
                                         written: true, channel: "C9", markedRead: nil)
        XCTAssertNil(advance)
        let failed = await queue.finish(tool: "slack_send_message", input: ["channel_id": "C1"],
                                        written: false, channel: nil, markedRead: nil)
        XCTAssertNil(failed)
    }

    func testDirectMessageMatchesByPersonIdAndLastOneCloses() async {
        let queue = LocalSlackQueue()
        await queue.start(snapshot([item("D1", withUser: "U5")]))
        let advance = await queue.finish(tool: "slack_add_reaction", input: ["channel_id": "U5"],
                                         written: true, channel: nil, markedRead: true)
        XCTAssertEqual(advance?.closed, true)
        XCTAssertTrue(advance?.text.contains("Every one of them is marked read") == true)
        let isRunning = await queue.isRunning
        XCTAssertFalse(isRunning)
    }

    func testStopReportsWhatIsLeftAndCloses() async {
        let queue = LocalSlackQueue()
        await queue.start(snapshot([item("C1"), item("C2"), item("C3")]))
        let stopped = await queue.step(direction: nil, restart: false, stop: true)
        XCTAssertTrue(stopped.closed)
        XCTAssertEqual(object(stopped.text)["remaining"] as? Int, 3)
    }

    func testWalkingPastTheLastCountsWhatWasMarked() async {
        let queue = LocalSlackQueue()
        await queue.start(snapshot([item("C1"), item("C2")]))
        _ = await queue.finish(tool: "slack_mark_read", input: ["channel_id": "C1"],
                               written: true, channel: "C1", markedRead: true,
                               now: Date().addingTimeInterval(-10))
        let done = await queue.step(direction: nil, restart: false, stop: false)
        let payload = object(done.text)
        XCTAssertTrue(done.closed)
        XCTAssertEqual(payload["markedRead"] as? Int, 1)
        XCTAssertEqual(payload["stillUnread"] as? Int, 1)
    }

    func testImportantStageOpensOnItsFirstConversationAndHandsBackToEmail() async {
        let queue = LocalSlackQueue()
        await queue.beginCall()
        let first = await queue.startImportant(snapshot([item("D1", withUser: "U5")]))
        XCTAssertFalse(first.closed)
        XCTAssertEqual((object(first.text)["item"] as? [String: Any])?["channel_id"] as? String, "D1")
        let advance = await queue.finish(tool: "slack_send_message", input: ["channel_id": "U5"],
                                         written: true, channel: nil, markedRead: true)
        XCTAssertEqual(advance?.closed, true)
        XCTAssertTrue(advance?.text.contains("call triage_next") == true)
    }

    func testImportantStageStopAlsoHandsBackToEmail() async {
        let queue = LocalSlackQueue()
        await queue.beginCall()
        _ = await queue.startImportant(snapshot([item("C1"), item("C2")]))
        let stopped = await queue.step(direction: nil, restart: false, stop: true)
        XCTAssertTrue(stopped.closed)
        XCTAssertTrue(stopped.text.contains("call triage_next"))
    }

    func testFeedStageLeavesOutWhatTheImportantStageWalked() async {
        let queue = LocalSlackQueue()
        await queue.beginCall()
        let all = snapshot([item("C1"), item("C2"), item("C3")])
        _ = await queue.startImportant(snapshot([item("C2")]))
        await queue.end()
        let remaining = await queue.unwalkedCount(all)
        XCTAssertEqual(remaining, 2)
        await queue.beginCall()
        let afterNewCall = await queue.unwalkedCount(all)
        XCTAssertEqual(afterNewCall, 3)
    }

    func testOrdinaryCloseDoesNotMentionEmail() async {
        let queue = LocalSlackQueue()
        await queue.start(snapshot([item("C1")]))
        let advance = await queue.finish(tool: "slack_mark_read", input: ["channel_id": "C1"],
                                         written: true, channel: "C1", markedRead: true)
        XCTAssertEqual(advance?.closed, true)
        XCTAssertFalse(advance?.text.contains("call triage_next in this same response") == true)
    }

    func testDeferredWriteThatFailsComesOffTheCloseCounts() async {
        let queue = LocalSlackQueue()
        await queue.start(snapshot([item("C1"), item("C2")]))
        let target = await queue.markTarget(input: ["channel_id": "C1"])
        _ = await queue.finish(tool: "slack_send_message", input: ["channel_id": "C1"],
                               written: true, channel: "C1", markedRead: true)
        await queue.writeFailed(try! XCTUnwrap(target))
        let closed = await queue.finish(tool: "slack_mark_read", input: ["channel_id": "C2"],
                                        written: true, channel: "C2", markedRead: true)
        let payload = object(closed?.text ?? "")
        XCTAssertEqual(payload["acted"] as? Int, 1)
        XCTAssertEqual(payload["markedRead"] as? Int, 1)
    }

    func testDeferredMarkThatFailsIsSaidAtTheNextStep() async {
        let queue = LocalSlackQueue()
        await queue.start(snapshot([item("C1"), item("C2"), item("C3")]))
        let target = await queue.markTarget(input: ["channel_id": "C1"])
        _ = await queue.finish(tool: "slack_add_reaction", input: ["channel_id": "C1"],
                               written: true, channel: "C1", markedRead: true,
                               now: Date().addingTimeInterval(-10))
        await queue.markFailed(try! XCTUnwrap(target))
        let next = await queue.step(direction: nil, restart: false, stop: false)
        XCTAssertTrue((object(next.text)["heardSince"] as? String)?.contains("could not be marked read") == true)
    }

    func testMarkTargetCarriesTheQueuedLabel() async {
        let queue = LocalSlackQueue()
        await queue.start(snapshot([item("D1", withUser: "U5")]))
        let target = await queue.markTarget(input: ["channel_id": "U5"])
        XCTAssertEqual(target?.channelId, "D1")
        XCTAssertEqual(target?.label, "#D1")
    }

    func testSnapshotWithoutBandStillDecodes() throws {
        let json = #"{"teamId":"T1","teamName":"Acme","channelId":"C1","label":"x","kind":"channel","#
            + #""unread":1,"more":false,"messages":[],"why":""}"#
        let decoded = try JSONDecoder().decode(SlackQueueSnapshot.Item.self, from: Data(json.utf8))
        XCTAssertNil(decoded.band)
        let banded = try JSONDecoder().decode(SlackQueueSnapshot.Item.self,
            from: Data(json.replacingOccurrences(of: #""why":"""#, with: #""why":"","band":"high""#).utf8))
        XCTAssertEqual(banded.band, "high")
    }
}
