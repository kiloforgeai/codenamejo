import XCTest
@testable import CodenameJo

final class TopicQueueTests: XCTestCase {
    private func item(_ id: String, thread: String? = nil, topic: String? = "order-12",
                      sender: String = "Store <sales@shop.test>", account: String = "owner@example.test") -> LocalTriageQueue.Item {
        LocalTriageQueue.Item(account: account, id: id, threadId: thread ?? "thread-" + id,
            from: sender, subject: "Update", date: "", snippet: "Order update", internalDate: 1, topicId: topic)
    }

    func testSameSenderAndMatterCollapseWithoutChangingIdentityOrCounts() {
        let a = item("a"), b = item("b")
        let grouped = LocalTriageQueue.groupByTopic([a, b, item("c", topic: "order-13")])
        XCTAssertEqual(grouped.count, 2)
        XCTAssertEqual(Set(grouped[0].ids), ["a", "b"])
        XCTAssertEqual(grouped[0].threadIDs, ["thread-a", "thread-b"])
        XCTAssertEqual(LocalTriageQueue.messageCount(grouped[0], scope: .unread, grouping: false), 2)
        XCTAssertEqual(grouped[0].unwrappedTopics.map(\.id), ["a", "b"])
    }

    func testDifferentSenderMailboxTopicAndUnknownStaySeparate() {
        let values = [item("a"), item("b", sender: "Other <other@shop.test>"),
                      item("c", account: "other@example.test"), item("d", topic: "other"), item("e", topic: nil)]
        XCTAssertEqual(LocalTriageQueue.groupByTopic(values).count, values.count)
    }

    func testReplyBranchesInTheSameThreadAreNotMergedByTopic() {
        XCTAssertEqual(LocalTriageQueue.groupByTopic([item("a", thread: "same"), item("b", thread: "same")]).count, 2)
    }

    func testExistingTopicGroupDoesNotSplitAnotherReplyChain() {
        let topic = LocalTriageQueue.groupByTopic([item("a"), item("b")])[0]
        func reply(_ id: String, references: String, parent: String) -> LocalTriageQueue.Item {
            var value = item(id, thread: "conversation", topic: nil)
            var member = value.conversation[0]
            member.rfcMessageID = "<\(id)@test>"
            member.inReplyTo = parent
            member.references = references
            value.messages = [member]
            return value
        }
        let first = reply("first", references: "<root@test>", parent: "<root@test>")
        let second = reply("second", references: "<root@test> <first@test>", parent: "<first@test>")
        let grouped = LocalTriageQueue.groupForPresentation([topic, first, second],
            grouping: true, topicGrouping: true, preserveOrder: true)
        XCTAssertEqual(grouped.count, 2)
        XCTAssertEqual(Set(grouped[0].ids), ["a", "b"])
        XCTAssertEqual(Set(grouped[1].ids), ["first", "second"])
        XCTAssertEqual(grouped.flatMap(\.ids).count, 4)
        XCTAssertEqual(LocalTriageQueue.groupForPresentation([topic, first, second],
            grouping: false, topicGrouping: true).count, 3)
    }

    func testMemberRemovalRestoresItsOwnThreadAndContext() throws {
        let grouped = LocalTriageQueue.groupByTopic([item("a"), item("b")])[0]
        let remaining = try XCTUnwrap(grouped.keeping(grouped.conversation.filter { $0.id == "b" }))
        XCTAssertEqual(remaining.threadId, "thread-b")
        XCTAssertEqual(remaining.ids, ["b"])
        XCTAssertFalse(remaining.isTopicGroup)
        XCTAssertEqual(LocalTriageQueue.resolvedReplyThreadId("a", in: [grouped]), "thread-a")
        XCTAssertEqual(LocalTriageQueue.unreadRemovalIDs(id: "a", verb: "archive_message", account: grouped.account,
                                                       presented: [grouped]), ["a"])
    }

    func testSelectionChangesWhenMembershipChangesAndSurvivesRoundTrip() throws {
        let grouped = LocalTriageQueue.groupByTopic([item("a"), item("b")])[0]
        let restored = try JSONDecoder().decode(LocalTriageQueue.Item.self, from: JSONEncoder().encode(grouped))
        XCTAssertEqual(LocalTriageQueue.topicSelectionID(grouped), LocalTriageQueue.topicSelectionID(restored))
        let larger = LocalTriageQueue.groupByTopic([grouped, item("c")])[0]
        XCTAssertNotEqual(LocalTriageQueue.topicSelectionID(grouped), LocalTriageQueue.topicSelectionID(larger))
        XCTAssertNotNil(LiveEmailPresentation.Key.item(grouped))
    }

    func testClusterPreparationSharesAllMembersAndReadContextInOneQuestion() throws {
        let previous = UserDefaults.standard.object(forKey: SuggestedActions.storageKey)
        defer { UserDefaults.standard.set(previous, forKey: SuggestedActions.storageKey) }
        UserDefaults.standard.set(true, forKey: SuggestedActions.storageKey)
        var first = item("a")
        first.exchangeContext = [.init(id: "read", from: "Store", subject: "Update",
            date: "", snippet: "Earlier context", internalDate: 0)]
        let group = LocalTriageQueue.groupByTopic([first, item("b"), item("c"), item("d")])[0]
        let key = try XCTUnwrap(LiveEmailPresentation.Key.item(group))
        XCTAssertEqual(key.messageIDs, ["a", "b", "c", "d", "read"])
        XCTAssertEqual(key.selectedIDs, ["a", "b", "c", "d"])
        XCTAssertEqual(key.messageThreads?["read"], "thread-a")
        let conversations = group.unwrappedTopics.map { part in
            ["messages": (part.conversation + (part.exchangeContext ?? [])).map {
                ["id": $0.id, "threadId": $0.threadId ?? part.threadId]
            }]
        }
        let payload: [String: Any] = ["done": false, "position": 2,
            "thread": LocalTriageQueue.threadStanding(group, scope: .unread)!,
            "item": ["account": group.account, "id": group.id, "threadId": group.threadId, "identity": "Store",
                     "exchangeId": group.displayGroupID!, "groupKind": "topic",
                     "messages": group.ids.map { ["id": $0] }, "conversations": conversations]]
        let step = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
        XCTAssertEqual(LiveEmailPresentation.Key.step(step), key)
        let question = "September 29 at 2pm PT is free for 30 minutes. Should I book it?"
        let prepared = LiveEmailPresentation(key: key, summary: "Store needs a delivery meeting.",
            from: "Store", to: group.account, sentAt: "2026-09-21T15:00:00Z", suggestedQuestion: question)
        let line = try XCTUnwrap(LiveSpokenStepContract.line(step: step, lead: "Next, ", prepared: prepared))
        XCTAssertEqual(line.components(separatedBy: question).count, 2)
        XCTAssertEqual(FullDuplexVoiceClient.presentableScript(step: step, lead: "Next, ", prepared: prepared), line)
        XCTAssertNil(FullDuplexVoiceClient.presentableScript(step: step, lead: "Next, ", prepared: nil))
        let annotated = try XCTUnwrap(prepared.annotating(step))
        let annotatedPayload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(annotated.utf8)) as? [String: Any])
        XCTAssertEqual((annotatedPayload["item"] as? [String: Any])?["suggestedQuestion"] as? String, question)
        XCTAssertNil(LiveSpokenStepContract.line(step: step, lead: "Next, "))
        let smaller = try XCTUnwrap(group.keeping(group.conversation.filter { $0.id != "a" }))
        XCTAssertNotEqual(LiveEmailPresentation.Key.item(smaller)?.identity, key.identity)
    }

    func testClusterPreparationNeverUsesAPartialLargeClusterOrHidesADraft() {
        let large = LocalTriageQueue.groupByTopic((0..<13).map { item("m\($0)") })[0]
        XCTAssertNil(LiveEmailPresentation.Key.item(large))
        var draft = item("draft")
        draft.hasDraft = true
        let group = LocalTriageQueue.groupByTopic([item("a"), draft])[0]
        XCTAssertNil(LiveEmailPresentation.Key.item(group))
    }

    func testAppendingNeverRewritesThePresentedTopicGroup() {
        let group = LocalTriageQueue.groupByTopic([item("a"), item("b")])[0]
        let appended = LocalTriageQueue.appendingPage([item("c")], to: [group], position: 1, grouping: false)
        XCTAssertEqual(Set(appended[0].ids), ["a", "b"])
        XCTAssertEqual(appended[1].ids, ["c"])
        var continuation = item("d")
        continuation.unresolvedContinuation = true
        XCTAssertEqual(LocalTriageQueue.groupByTopic([item("e"), continuation]).count, 2)
    }
}
