import XCTest
import GRDB
import FactoryKit
@testable import CodenameJo

@MainActor
final class ConversationQueueIntegrationTests: XCTestCase {
    private let account = "queue@example.test"
    private var previousFlag: Any?
    private var previousScope: String?

    override func setUp() {
        super.setUp()
        previousFlag = UserDefaults.standard.object(forKey: ThreadQueue.storageKey)
        UserDefaults.standard.set(true, forKey: ThreadQueue.storageKey)
        // These tests pin walk mechanics over the unread pile, seeded with fixed old dates. The
        // automatic start is the week ranked by importance since #982, so they pick unread the
        // way a Settings choice would; the tests about the default clear it themselves.
        previousScope = UserDefaults.standard.string(forKey: TriageScope.storageKey)
        TriageScope.store(.unread)
    }

    override func tearDown() {
        if let previousFlag { UserDefaults.standard.set(previousFlag, forKey: ThreadQueue.storageKey) }
        else { UserDefaults.standard.removeObject(forKey: ThreadQueue.storageKey) }
        if let previousScope { UserDefaults.standard.set(previousScope, forKey: TriageScope.storageKey) }
        else { TriageScope.clear() }
        super.tearDown()
    }

    private func topicTestBatch() -> [MailStore.Ingest] {
        (0..<10).map { index in
            let detail = GmailAPI.MessageDetail(id: "fresh-\(index)", threadId: "thread-\(index)",
                labelIds: ["INBOX", "UNREAD"], snippet: "Update \(index)",
                internalDate: String(100_000 - index * 1_000),
                payload: .init(headers: [.init(name: "From", value: "sales@shop.test"),
                                          .init(name: "Subject", value: "Update \(index)")]))
            return MailStore.Ingest(detail: detail, account: account)
        }
    }

    func testBackgroundPreparationAddsClassifiedArrivalsBehindNonemptyCurrent() async throws {
        let fixture = try StoreFixture()
        defer { fixture.close() }
        UserDefaults.standard.set(false, forKey: ThreadQueue.storageKey)
        let andrew = row("andrew", thread: "invitation", date: 1, sender: "Andrew")
        try await fixture.seed([andrew], unread: ["andrew"])
        let queue = makeQueue()
        _ = await queue.step(.init(restart: true, scope: .unread), store: fixture.store)
        await fixture.store.cache(topicTestBatch())
        var topics: [String: String] = [:]
        for index in 0..<10 {
            topics["fresh-\(index)"] = index < 5 ? "notebooks" : index < 8 ? "lamps" : "newsletter-\(index)"
        }
        await fixture.store.applyTopics(topics, version: 1, account: account)
        await queue.refreshTopicMembership(store: fixture.store, includeArrivals: true)
        let progress = await queue.progress
        XCTAssertEqual(progress?.displayQueued, 5)
        XCTAssertEqual(progress?.queued, 11)
        let stillCurrent = await queue.step(.init(account: account), store: fixture.store)
        XCTAssertEqual(try current(stillCurrent.output)["id"] as? String, "andrew")
        let next = await queue.step(.init(), store: fixture.store, dealtWith: false)
        XCTAssertEqual((try current(next.output)["messages"] as? [[String: Any]])?.count, 5)
        let lamps = await queue.step(.init(), store: fixture.store, dealtWith: false)
        XCTAssertEqual((try current(lamps.output)["messages"] as? [[String: Any]])?.count, 3)
        await queue.end()
    }

    func testExhaustingNonemptyUnreadFindsNewMailBeforeAllMail() async throws {
        let fixture = try StoreFixture()
        defer { fixture.close() }
        UserDefaults.standard.set(false, forKey: ThreadQueue.storageKey)
        let priorScope = UserDefaults.standard.object(forKey: TriageScope.storageKey)
        UserDefaults.standard.removeObject(forKey: TriageScope.storageKey)
        defer { UserDefaults.standard.set(priorScope, forKey: TriageScope.storageKey) }
        let andrew = row("andrew", thread: "invitation", date: 1, sender: "Andrew")
        try await fixture.seed([andrew], unread: ["andrew"])
        await fixture.store.applyBands(["andrew": ("normal", "", 5)], account: account)
        let batch = topicTestBatch()
        let queue = LocalTriageQueue(liveFeatures: true, mailAccounts: { ["queue@example.test"] },
                                    unreadOpeningLoader: { _ in batch })
        let opening = await queue.step(.init(restart: true), store: fixture.store)
        XCTAssertEqual(try current(opening.output)["id"] as? String, "andrew")
        let next = await queue.step(.init(), store: fixture.store, dealtWith: false)
        XCTAssertEqual(try current(next.output)["id"] as? String, "fresh-0")
        let progress = await queue.progress
        XCTAssertNotNil(progress?.displayQueued, "New mail must remain in the topic-enabled unread scope")
        await queue.end()
    }

    func testUnreadRecheckIsReadOnTheLastMessageSoLeavingUnreadDoesNotWaitOnGmail() async throws {
        let fixture = try StoreFixture()
        defer { fixture.close() }
        UserDefaults.standard.set(false, forKey: ThreadQueue.storageKey)
        let rows = [row("first", thread: "first", date: 2, sender: "Andrew"),
                    row("last", thread: "last", date: 1, sender: "Beth")]
        try await fixture.seed(rows, unread: ["first", "last"])
        let reads = LoaderCalls(results: [[]])
        let queue = LocalTriageQueue(liveFeatures: true, mailAccounts: { ["queue@example.test"] },
                                    unreadOpeningLoader: { _ in reads.next() })
        let opening = await queue.step(.init(restart: true, scope: .unread), store: fixture.store)
        XCTAssertEqual(try current(opening.output)["id"] as? String, "first")
        XCTAssertEqual(reads.count, 0, "Nothing is re-checked while unread has more than its last message")
        let last = await queue.step(.init(), store: fixture.store, dealtWith: false)
        XCTAssertEqual(try current(last.output)["id"] as? String, "last")
        try await waitUntil { reads.count == 1 }
        let leaving = await queue.step(.init(), store: fixture.store, dealtWith: false)
        XCTAssertEqual(reads.count, 1, "The crossing uses the re-check read on the last message")
        XCTAssertEqual(leaving.served, .hit)
        await queue.end()
    }

    func testAFailedUnreadRecheckAheadIsReadAgainLiveAtTheCrossing() async throws {
        let fixture = try StoreFixture()
        defer { fixture.close() }
        UserDefaults.standard.set(false, forKey: ThreadQueue.storageKey)
        try await fixture.seed([row("only", thread: "only", date: 1, sender: "Andrew")], unread: ["only"])
        let reads = LoaderCalls(results: [nil, []])
        let queue = LocalTriageQueue(liveFeatures: true, mailAccounts: { ["queue@example.test"] },
                                    unreadOpeningLoader: { _ in reads.next() })
        let opening = await queue.step(.init(restart: true, scope: .unread), store: fixture.store)
        XCTAssertEqual(try current(opening.output)["id"] as? String, "only")
        try await waitUntil { reads.count == 1 }
        let leaving = await queue.step(.init(), store: fixture.store, dealtWith: false)
        XCTAssertEqual(reads.count, 2)
        XCTAssertEqual(leaving.served, .live, "The user waited on the second read")
        XCTAssertEqual(try object(leaving.output)["done"] as? Bool, true)
        await queue.end()
    }

    func testUnpresentedSnapshotCanGroupItsOpeningAfterClassification() async throws {
        let fixture = try StoreFixture()
        defer { fixture.close() }
        UserDefaults.standard.set(false, forKey: ThreadQueue.storageKey)
        await fixture.store.cache(topicTestBatch())
        await fixture.store.apply([], account: account, historyId: nil, inboxUnread: 10)
        let queue = makeQueue()
        await queue.prepareDailySnapshot(store: fixture.store)
        let topics = Dictionary(uniqueKeysWithValues: (0..<10).map { ("fresh-\($0)", "one-order") })
        await fixture.store.applyTopics(topics, version: 1, account: account)
        let opening = await queue.step(.init(scope: .unread), store: fixture.store)
        XCTAssertEqual((try current(opening.output)["messages"] as? [[String: Any]])?.count, 10)
        await queue.end()
    }

    func testEmptyInboxThenNewMailKeepsUnreadAndGroupsOnlyUnseenItems() async throws {
        let fixture = try StoreFixture()
        defer { fixture.close() }
        UserDefaults.standard.set(false, forKey: ThreadQueue.storageKey)
        await fixture.store.apply([], account: account, historyId: nil, inboxUnread: 0)
        let batch = topicTestBatch()
        let queue = LocalTriageQueue(mailAccounts: { ["queue@example.test"] },
                                    unreadOpeningLoader: { _ in batch })
        let opening = await queue.step(.init(restart: true, scope: .unread), store: fixture.store)
        XCTAssertEqual(try current(opening.output)["id"] as? String, "fresh-0")
        let initial = await queue.progress
        XCTAssertEqual(initial?.displayQueued, 10)
        var topics: [String: String] = [:]
        for index in 0..<10 {
            topics["fresh-\(index)"] = index < 5 ? "notebooks" : index < 8 ? "lamps" : "newsletter-\(index)"
        }
        await fixture.store.applyTopics(topics, version: 1, account: account)
        await queue.refreshTopicMembership(store: fixture.store)
        let refreshed = await queue.progress
        // The already presented notebook stays frozen; its four siblings form a continuation.
        XCTAssertEqual(refreshed?.displayQueued, 5)
        XCTAssertEqual(refreshed?.queued, 10)
        let currentAgain = await queue.step(.init(account: account), store: fixture.store)
        XCTAssertEqual(try current(currentAgain.output)["id"] as? String, "fresh-0")
        XCTAssertNil(try current(currentAgain.output)["groupKind"])
        // Importance arriving with topics must not discard the frozen current on resume.
        await fixture.store.applyBands(Dictionary(uniqueKeysWithValues: batch.map {
            ($0.message.id, (band: "normal", why: "", score: Optional(5)))
        }), account: account)
        await queue.end()
        let resumed = makeQueue()
        let restored = await resumed.step(.init(scope: .unread), store: fixture.store)
        XCTAssertEqual(try current(restored.output)["id"] as? String, "fresh-0")
        XCTAssertNil(try current(restored.output)["groupKind"])
        let next = await resumed.step(.init(), store: fixture.store, dealtWith: false)
        XCTAssertEqual((try current(next.output)["messages"] as? [[String: Any]])?.count, 4)
        let lamps = await resumed.step(.init(), store: fixture.store, dealtWith: false)
        XCTAssertEqual((try current(lamps.output)["messages"] as? [[String: Any]])?.count, 3)
        await resumed.end()
    }

    func testAutomaticOpeningLeavesSavedAllMailFallbackForNewUnclassifiedUnread() async throws {
        let fixture = try StoreFixture()
        defer { fixture.close() }
        let prior = UserDefaults.standard.object(forKey: TriageScope.storageKey)
        UserDefaults.standard.removeObject(forKey: TriageScope.storageKey)
        defer { UserDefaults.standard.set(prior, forKey: TriageScope.storageKey) }
        UserDefaults.standard.set(false, forKey: ThreadQueue.storageKey)
        let old = row("old-read", thread: "old-thread", date: 1, sender: "Old")
        try await fixture.seed([old], unread: [])
        await fixture.store.apply([], account: account, historyId: nil, inboxUnread: 0)
        try await saveSnapshot([item(old)], store: fixture.store, scope: "all", scopePlan: ["unread", "all"])
        let batch = topicTestBatch()
        let queue = LocalTriageQueue(mailAccounts: { ["queue@example.test"] },
                                    unreadOpeningLoader: { _ in batch })
        let opening = await queue.openingStep(store: fixture.store)
        XCTAssertEqual(try current(opening.output)["id"] as? String, "fresh-0")
        let progress = await queue.progress
        XCTAssertEqual(progress?.displayQueued, 10, "Unread grouping mode must be enabled without waiting for bands")
        await queue.end()
    }

    func testExplicitAllMailResumeDoesNotProbeUnread() async throws {
        let fixture = try StoreFixture()
        defer { fixture.close() }
        let old = row("old-read", thread: "old-thread", date: 1, sender: "Old")
        try await fixture.seed([old], unread: [])
        try await saveSnapshot([item(old)], store: fixture.store, scope: "all", scopePlan: ["unread", "all"])
        let queue = LocalTriageQueue(mailAccounts: { ["queue@example.test"] },
                                    unreadOpeningLoader: { _ in
            XCTFail("Explicit all-mail must not switch to unread")
            return nil
        })
        let opening = await queue.step(.init(scope: .all), store: fixture.store)
        XCTAssertEqual(try current(opening.output)["id"] as? String, "old-read")
        let progress = await queue.progress
        XCTAssertNil(progress?.displayQueued)
        await queue.end()
    }

    func testFailedUnreadRefreshDoesNotTreatCachedZeroAsEmpty() async throws {
        let fixture = try StoreFixture()
        defer { fixture.close() }
        await fixture.store.apply([], account: account, historyId: nil, inboxUnread: 0)
        let queue = LocalTriageQueue(mailAccounts: { ["queue@example.test"] },
                                    unreadOpeningLoader: { _ in nil })
        let opening = await queue.step(.init(restart: true, scope: .unread), store: fixture.store)
        XCTAssertNil(try object(opening.output)["empty"])
        XCTAssertNotEqual(try object(opening.output)["done"] as? Bool, true)
        XCTAssertNotNil(try object(opening.output)["note"])
        await queue.end()
    }

    func testFiveTopicMessagesDisplayAsOneQueueStop() async throws {
        let fixture = try StoreFixture()
        defer { fixture.close() }
        UserDefaults.standard.set(false, forKey: ThreadQueue.storageKey)
        let rows = (1...5).map { row("mail-\($0)", thread: "thread-\($0)",
                                    date: Int64(100 - $0), sender: "sales@shop.test") }
        try await fixture.seed(rows, unread: Set(rows.map(\.id)))
        await fixture.store.applyTopics(Dictionary(uniqueKeysWithValues: rows.map {
            ($0.id, "order12")
        }), version: 1, account: account)
        await fixture.store.applyBands(Dictionary(uniqueKeysWithValues: rows.map {
            ($0.id, (band: "normal", why: "", score: Optional(8)))
        }), account: account)
        let queue = makeQueue()
        _ = await queue.step(.init(restart: true, scope: .unread), store: fixture.store)
        let progress = await queue.progress
        XCTAssertEqual(progress?.queued, 5)
        XCTAssertEqual(progress?.displayPosition, 1)
        XCTAssertEqual(progress?.displayQueued, 1)
        XCTAssertEqual(progress?.displayRemaining, 1)
        let standing = await queue.standing
        XCTAssertEqual(standing?.position, 1)
        XCTAssertEqual(standing?.total, 1)
        let chip = TriageQueueStore()
        chip.applyLocal(progress)
        XCTAssertEqual(chip.progress?.position, 1)
        XCTAssertEqual(chip.progress?.queued, 1)
        XCTAssertEqual(chip.progress?.remaining, 1)
        await queue.end()
    }

    func testPendingArchiveOfExplicitTopicMemberLeavesOtherThreadCurrent() async throws {
        let fixture = try StoreFixture()
        defer { fixture.close() }
        UserDefaults.standard.set(false, forKey: ThreadQueue.storageKey)
        let rows = [row("a", thread: "ta", date: 30, sender: "sales@shop.test"),
                    row("b", thread: "tb", date: 20, sender: "sales@shop.test")]
        try await fixture.seed(rows, unread: ["a", "b"])
        await fixture.store.applyTopics(["a": "order12", "b": "order12"], version: 1, account: account)
        await fixture.store.applyBands(["a": ("normal", "", 9), "b": ("normal", "", 8)], account: account)
        let queue = makeQueue()
        _ = await queue.step(.init(restart: true, scope: .unread), store: fixture.store)
        let archived = await queue.acceptPendingArchive(.init(id: "retry-a", account: account, messageId: "a", threadId: "ta"))
        XCTAssertEqual(archived, "a")
        let next = await queue.step(.init(), store: fixture.store, dealtWith: false)
        XCTAssertEqual(try current(next.output)["id"] as? String, "b")
        let unread = await fixture.store.unreadIds(among: ["a", "b"])
        XCTAssertEqual(unread, ["a", "b"])
        await queue.end()
    }

    func testTopicResumeKeepsPresentedMembershipWhenNewSameTopicMailArrives() async throws {
        let fixture = try StoreFixture()
        defer { fixture.close() }
        UserDefaults.standard.set(false, forKey: ThreadQueue.storageKey)
        let rows = [row("a", thread: "ta", date: 30, sender: "sales@shop.test"),
                    row("b", thread: "tb", date: 20, sender: "sales@shop.test")]
        try await fixture.seed(rows, unread: ["a", "b"])
        await fixture.store.applyTopics(["a": "order12", "b": "order12"], version: 1, account: account)
        await fixture.store.applyBands(["a": ("normal", "", 9), "b": ("normal", "", 8)], account: account)
        let queue = makeQueue()
        _ = await queue.step(.init(restart: true, scope: .unread), store: fixture.store)
        await queue.end()
        let arrival = row("new", thread: "tn", date: 40, sender: "sales@shop.test")
        try await fixture.seed([arrival], unread: ["new"])
        await fixture.store.applyTopics(["new": "order12"], version: 1, account: account)
        await fixture.store.applyBands(["new": ("high", "", 10)], account: account)
        let resumed = makeQueue()
        let opening = await resumed.step(.init(scope: .unread), store: fixture.store)
        let members = (try current(opening.output)["messages"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        XCTAssertEqual(Set(members), ["a", "b"])
        let next = await resumed.step(.init(), store: fixture.store, dealtWith: false)
        XCTAssertEqual(try current(next.output)["id"] as? String, "new")
        await resumed.end()
    }

    func testTopicWalkCollectsSiblingsAcrossBandsAndNextLeavesWholeGroup() async throws {
        let fixture = try StoreFixture()
        defer { fixture.close() }
        UserDefaults.standard.set(false, forKey: ThreadQueue.storageKey)
        let rows = [row("a", thread: "ta", date: 30, sender: "Shop <sales@shop.test>"),
                    row("b", thread: "tb", date: 20, sender: "Shop <sales@shop.test>"),
                    row("c", thread: "tc", date: 10, sender: "Shop <sales@shop.test>")]
        try await fixture.seed(rows, unread: ["a", "b", "c"])
        await fixture.store.applyTopics(["a": "order12", "b": "order12", "c": "order13"], version: 1, account: account)
        await fixture.store.applyBands(["a": ("high", "", 9), "b": ("low", "", 1), "c": ("normal", "", 4)], account: account)
        let queue = makeQueue()
        let opening = await queue.step(.init(restart: true, scope: .unread), store: fixture.store)
        let group = try current(opening.output)
        XCTAssertEqual(group["groupKind"] as? String, "topic")
        XCTAssertEqual(Set((group["messages"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }), ["a", "b"])
        let next = await queue.step(.init(), store: fixture.store, dealtWith: false)
        XCTAssertEqual(try current(next.output)["id"] as? String, "c")
        XCTAssertEqual(try object(next.output)["position"] as? Int, 3)
        let progress = await queue.progress
        XCTAssertEqual(progress?.position, 3)
        XCTAssertEqual(progress?.displayPosition, 2)
        XCTAssertEqual(progress?.displayQueued, 2)
        await queue.end()
    }

    func testTopicPartialArchiveKeepsFailedMemberAndRejectsStaleSelection() async throws {
        let fixture = try StoreFixture()
        defer { fixture.close() }
        UserDefaults.standard.set(false, forKey: ThreadQueue.storageKey)
        let rows = [row("a", thread: "ta", date: 30, sender: "sales@shop.test"),
                    row("b", thread: "tb", date: 20, sender: "sales@shop.test")]
        try await fixture.seed(rows, unread: ["a", "b"])
        await fixture.store.applyTopics(["a": "order12", "b": "order12"], version: 1, account: account)
        await fixture.store.applyBands(["a": ("normal", "", 9), "b": ("normal", "", 8)], account: account)
        let queue = makeQueue()
        let opening = await queue.step(.init(restart: true, scope: .unread), store: fixture.store)
        let selection = try XCTUnwrap(current(opening.output)["archiveGroupId"] as? String)
        let targets = await queue.topicArchiveTargets(selection: selection, account: account)
        XCTAssertEqual(targets?.count, 2)
        let effect = GmailWriteEffect(account: account, scope: "thread", threadId: "ta",
            messageIds: ["a"], messageIdsComplete: true, operation: "modify", removeLabelIds: ["INBOX"])
        let advanced = await queue.finishTopicArchive(selection: selection, accepted: ["a"], pending: [], effects: [effect], store: fixture.store)
        XCTAssertTrue(advanced)
        let next = await queue.step(.init(), store: fixture.store, dealtWith: true)
        XCTAssertEqual(try current(next.output)["id"] as? String, "b")
        let stale = await queue.topicArchiveTargets(selection: selection, account: account)
        XCTAssertEqual(stale?.count, 0)
        let inbox = await fixture.store.inboxIds(among: ["a", "b"], account: account)
        XCTAssertEqual(inbox, ["b"])
        await queue.end()
    }

    func testBandedRestorePrefetchesAtEightAndCrossesPagesWithoutExtraNext() async throws {
        let cadenceKey = "dailyEmailQueueCoachingCadence.\(Container.shared.backend().userId ?? "")"
        let previousCadence = UserDefaults.standard.object(forKey: cadenceKey)
        UserDefaults.standard.removeObject(forKey: cadenceKey)
        defer { UserDefaults.standard.set(previousCadence, forKey: cadenceKey) }
        let fixture = try StoreFixture()
        defer { fixture.close() }
        UserDefaults.standard.set(false, forKey: ThreadQueue.storageKey)
        let rows = (1...36).map { index in
            row("mail-\(index)", thread: "thread-\(index)", date: Int64(100 - index), sender: "Sender")
        }
        try await fixture.seed(rows, unread: Set(rows.map(\.id)))
        await fixture.store.applyBands(Dictionary(uniqueKeysWithValues: rows.map {
            ($0.id, (band: "high", why: "reply", score: Optional(9)))
        }), account: account)
        // Reproduce #840's mailbox-sized snapshot, including its exhausted paging flag.
        try await saveSnapshot(rows.map(item), store: fixture.store, grouping: false, band: "high")
        let queue = makeQueue()
        let refilled = expectation(description: "Page two prepared before item nine")
        refilled.assertForOverFulfill = false
        await queue.configure(coachingPlan: .init(lessons: []),
            forceOnboardingFeedLesson: false, sequentialFeed: true,
            calendarFeedDue: false, localCalendar: false,
            preparationChanged: { refilled.fulfill() })
        let opening = await queue.step(.init(scope: .unread), store: fixture.store)
        XCTAssertEqual(try current(opening.output)["id"] as? String, "mail-1")
        let initial = await queue.progress
        XCTAssertEqual(initial?.queued, 12)
        for index in 2...8 {
            let next = await queue.step(.init(), store: fixture.store, dealtWith: true)
            XCTAssertEqual(try current(next.output)["id"] as? String, "mail-\(index)")
        }
        await fulfillment(of: [refilled], timeout: 5)
        let prefetched = await queue.progress
        XCTAssertEqual(prefetched?.queued, 24)
        for index in 9...36 {
            let next = await queue.step(.init(), store: fixture.store, dealtWith: true)
            XCTAssertEqual(try current(next.output)["id"] as? String, "mail-\(index)")
            XCTAssertEqual(try object(next.output)["position"] as? Int, index)
        }
        await queue.end()
    }

    func testBandedResumeKeepsCurrentAndDoesNotSkipRankedMailAcrossPages() async throws {
        let fixture = try StoreFixture()
        defer { fixture.close() }
        UserDefaults.standard.set(false, forKey: ThreadQueue.storageKey)
        let rows = (1...37).map { index in
            row("mail-\(index)", thread: "thread-\(index)", date: Int64(100 - index), sender: "Sender")
        }
        try await fixture.seed(rows, unread: Set(rows.map(\.id)))
        var bands: [String: (band: String, why: String, score: Int?)] = [:]
        for index in 1...37 {
            bands["mail-\(index)"] = (index <= 18 ? "high" : index <= 34 ? "normal" : "low",
                "", index <= 9 ? 10 : index <= 18 ? 9 : index <= 34 ? 8 : 1)
        }
        await fixture.store.applyBands(bands, account: account)
        try await saveSnapshot(rows.map(item), store: fixture.store, grouping: false,
            position: 37, band: "low")
        let queue = makeQueue()
        let opening = await queue.step(.init(scope: .unread), store: fixture.store)
        XCTAssertEqual(try current(opening.output)["id"] as? String, "mail-37")
        for index in 1...36 {
            let next = await queue.step(.init(), store: fixture.store, dealtWith: true)
            XCTAssertEqual(try current(next.output)["id"] as? String, "mail-\(index)")
        }
        let terminal = try object(await queue.step(.init(), store: fixture.store, dealtWith: true).output)
        XCTAssertEqual(terminal["done"] as? Bool, true)
        await queue.end()
    }

    func testPageCheckpointStillPresentsDueCalendarThenContinuesOnlyOnce() async throws {
        let cadenceKey = "dailyEmailQueueCoachingCadence.\(Container.shared.backend().userId ?? "")"
        let previousCadence = UserDefaults.standard.object(forKey: cadenceKey)
        UserDefaults.standard.removeObject(forKey: cadenceKey)
        defer { UserDefaults.standard.set(previousCadence, forKey: cadenceKey) }
        let fixture = try StoreFixture()
        defer { fixture.close() }
        UserDefaults.standard.set(false, forKey: ThreadQueue.storageKey)
        let rows = (1...25).map { index in
            row("mail-\(index)", thread: "thread-\(index)", date: Int64(100 - index), sender: "Sender")
        }
        try await fixture.seed(rows, unread: Set(rows.map(\.id)))
        let queue = makeQueue()
        await queue.configure(coachingPlan: .init(lessons: []),
            forceOnboardingFeedLesson: false, sequentialFeed: true,
            calendarFeedDue: true, localCalendar: false)
        await queue.adopt(rows, store: fixture.store)
        for _ in 2...12 { _ = await queue.step(.init(), store: fixture.store, dealtWith: true) }
        let checkpoint = try object(await queue.step(.init(), store: fixture.store, dealtWith: true).output)
        XCTAssertEqual(checkpoint["interstitial"] as? String, "page")
        XCTAssertEqual(checkpoint["calendarDue"] as? Bool, true)
        for index in 13...25 {
            let next = await queue.step(.init(), store: fixture.store, dealtWith: true)
            XCTAssertEqual(try current(next.output)["id"] as? String, "mail-\(index)")
        }
        await queue.end()
    }

    /// #989: a dispatch handoff that crossed the twelfth message served the tip, and the
    /// job's answer then landed inside the lesson. The handoff gets an email; the tip waits.
    func testDispatchHandoffDefersTheCoachingCheckpointToTheNextStep() async throws {
        let cadenceKey = "dailyEmailQueueCoachingCadence.\(Container.shared.backend().userId ?? "")"
        let previousCadence = UserDefaults.standard.object(forKey: cadenceKey)
        UserDefaults.standard.removeObject(forKey: cadenceKey)
        defer { UserDefaults.standard.set(previousCadence, forKey: cadenceKey) }
        let fixture = try StoreFixture()
        defer { fixture.close() }
        UserDefaults.standard.set(false, forKey: ThreadQueue.storageKey)
        let rows = (1...14).map { index in
            row("mail-\(index)", thread: "thread-\(index)", date: Int64(100 - index), sender: "Sender")
        }
        try await fixture.seed(rows, unread: Set(rows.map(\.id)))
        let queue = makeQueue()
        // Sequential, like every email-queue mint: the page checkpoint is the one that fired.
        await queue.configure(coachingPlan: .init(lessons: []),
            forceOnboardingFeedLesson: false, sequentialFeed: true,
            calendarFeedDue: true, localCalendar: false)
        await queue.adopt(rows, store: fixture.store)
        for _ in 2...12 { _ = await queue.step(.init(), store: fixture.store, dealtWith: true) }

        var handoff = LocalTriageQueue.Input(direction: "next")
        handoff.defersCoaching = true
        let advanced = await queue.step(handoff, store: fixture.store, dealtWith: false)
        XCTAssertEqual(try current(advanced.output)["id"] as? String, "mail-13")

        let tip = try object(await queue.step(.init(), store: fixture.store, dealtWith: true).output)
        XCTAssertEqual(tip["interstitial"] as? String, "page")
        let resumed = await queue.step(.init(), store: fixture.store, dealtWith: true)
        XCTAssertEqual(try current(resumed.output)["id"] as? String, "mail-14")
        await queue.end()
    }

    private func slackLoaded(_ bands: [String?]) -> SlackQueueCache.Loaded {
        let items = bands.enumerated().map { index, band in
            SlackQueueSnapshot.Item(
                teamId: "T1", teamName: "Acme", channelId: "C\(index)", withUserId: nil,
                label: "room \(index)", kind: "channel", unread: 1, more: false,
                messages: [.init(from: "Sam", fromId: "U9", ts: "1.\(index)", text: "can you look?",
                                 threadTs: nil, replies: nil)],
                why: "", band: band)
        }
        return .init(generatedAt: Date(), teams: ["T1"], queue: .init(
            workspaces: ["Acme"], total: items.count, items: items,
            report: .init(workspacesUnavailable: nil, unchecked: 0, unreachable: 0,
                          readStateUnknown: 0, dmsUnavailable: nil, markUnavailable: nil)))
    }

    private func importantSlackQueue(_ rows: [MailStore.Message], fixture: StoreFixture,
                                     slack: SlackQueueCache.Loaded) async throws -> LocalTriageQueue {
        try await fixture.seed(rows, unread: Set(rows.map(\.id)))
        let queue = makeQueue()
        await queue.configure(coachingPlan: .init(lessons: []),
            forceOnboardingFeedLesson: false, sequentialFeed: true,
            calendarFeedDue: false, dynamicSlackFeed: true, importantSlackStage: true,
            localCalendar: false)
        await queue.installSlackPrefetch(slack, profileId: ProfileRuntime.snapshot?.profileId)
        await queue.adopt(rows, store: fixture.store)
        await Container.shared.localSlack().beginCall()
        return queue
    }

    private func banded(_ id: String, _ band: String, date: Int64) -> MailStore.Message {
        var message = row(id, thread: "thread-\(id)", date: date, sender: "Sender")
        message.importanceBand = band
        return message
    }

    func testImportantSlackComesBetweenImportantMailAndTheRest() async throws {
        let fixture = try StoreFixture()
        defer { fixture.close() }
        UserDefaults.standard.set(false, forKey: ThreadQueue.storageKey)
        let rows = [banded("a", "high", date: 40), banded("b", "high", date: 30),
                    banded("c", "normal", date: 20), banded("d", "low", date: 10)]
        let queue = try await importantSlackQueue(
            rows, fixture: fixture, slack: slackLoaded(["high", "normal"]))
        let second = await queue.step(.init(), store: fixture.store, dealtWith: true)
        XCTAssertEqual(try current(second.output)["id"] as? String, "b")
        let slack = try object(await queue.step(.init(), store: fixture.store, dealtWith: true).output)
        XCTAssertEqual(slack["interstitial"] as? String, "slack")
        let step = try XCTUnwrap(slack["slackStep"] as? [String: Any])
        XCTAssertEqual(step["queued"] as? Int, 1, "only the high-band conversation")
        XCTAssertEqual((step["item"] as? [String: Any])?["channel_id"] as? String, "C0")
        let resumed = await queue.step(.init(), store: fixture.store, dealtWith: true)
        XCTAssertEqual(try current(resumed.output)["id"] as? String, "c", "the held email is served, not skipped")
        let last = await queue.step(.init(), store: fixture.store, dealtWith: true)
        XCTAssertEqual(try current(last.output)["id"] as? String, "d", "once per call")
        await Container.shared.localSlack().beginCall()
        await queue.end()
    }

    func testNoImportantSlackMeansNoStage() async throws {
        let fixture = try StoreFixture()
        defer { fixture.close() }
        UserDefaults.standard.set(false, forKey: ThreadQueue.storageKey)
        let rows = [banded("a", "high", date: 30), banded("b", "normal", date: 20)]
        let queue = try await importantSlackQueue(
            rows, fixture: fixture, slack: slackLoaded(["normal", nil]))
        let next = await queue.step(.init(), store: fixture.store, dealtWith: true)
        XCTAssertEqual(try current(next.output)["id"] as? String, "b")
        await queue.end()
    }

    func testUnbandedWalkGetsImportantSlackAfterTheOpeningEmail() async throws {
        let fixture = try StoreFixture()
        defer { fixture.close() }
        UserDefaults.standard.set(false, forKey: ThreadQueue.storageKey)
        let rows = [row("a", thread: "ta", date: 30, sender: "Sender"),
                    row("b", thread: "tb", date: 20, sender: "Sender")]
        let queue = try await importantSlackQueue(rows, fixture: fixture, slack: slackLoaded(["high"]))
        let slack = try object(await queue.step(.init(), store: fixture.store, dealtWith: true).output)
        XCTAssertEqual(slack["interstitial"] as? String, "slack")
        let resumed = await queue.step(.init(), store: fixture.store, dealtWith: true)
        XCTAssertEqual(try current(resumed.output)["id"] as? String, "b")
        await Container.shared.localSlack().beginCall()
        await queue.end()
    }

    func testThreadReadCheckDoesNotCacheArchivedUnreadMembers() async throws {
        let fixture = try StoreFixture()
        defer { fixture.close() }
        let json = #"{"id":"thread","messages":[{"id":"inbox","threadId":"thread","labelIds":["INBOX"],"internalDate":"30"},{"id":"archived","threadId":"thread","labelIds":["UNREAD"],"internalDate":"20"}]}"#
        let thread = try JSONDecoder().decode(GmailAPI.ThreadMetadata.self, from: Data(json.utf8))
        let verified = await LocalTriageQueue.cacheThreadReadState(
            thread, expectedID: "thread", account: account, store: fixture.store)
        XCTAssertFalse(verified, "Archived unread members still prevent a fully read thread summary")
        let unread = await fixture.store.unreadPage(before: nil, limit: 12, account: account)
        XCTAssertTrue(unread.isEmpty, "Thread context must not introduce archived mail into the inbox queue")
        let inbox = await fixture.store.inboxIds(among: ["inbox"])
        XCTAssertEqual(inbox, ["inbox"])
    }

    private func effect(_ ids: [String], complete: Bool = true, add: [String] = [], remove: [String] = ["INBOX"],
                        mailbox: String? = nil) -> GmailWriteEffect {
        GmailWriteEffect(account: mailbox ?? account, scope: "thread", threadId: "thread", messageIds: ids,
                         messageIdsComplete: complete, operation: "modify", addLabelIds: add, removeLabelIds: remove)
    }

    func testConfirmedThreadArchivePreservesLaterArrivalAndUnreadFacts() async throws {
        let fixture = try StoreFixture()
        defer { fixture.close() }
        let rows = [row("a", thread: "thread", date: 30, sender: "Sam"),
                    row("b", thread: "thread", date: 20, sender: "Priya"),
                    row("later", thread: "thread", date: 10, sender: "Dana")]
        try await fixture.seed(rows, unread: Set(rows.map(\.id)))
        let queue = makeQueue()
        await queue.adopt(rows, store: fixture.store)
        let finished = await queue.applyConfirmedEffects([effect(["a", "b"])], store: fixture.store)
        XCTAssertNotNil(finished)
        let unreadFacts = await fixture.store.unreadIds(among: rows.map(\.id))
        XCTAssertEqual(unreadFacts, Set(rows.map(\.id)))
        let unreadInbox = await fixture.store.unreadPage(before: nil, limit: 12, account: account)
        XCTAssertEqual(unreadInbox.map(\.id), ["later"])
        let next = await queue.step(.init(), store: fixture.store, dealtWith: false)
        XCTAssertEqual(try current(next.output)["id"] as? String, "later")
        await queue.end()
    }

    func testIncompleteThreadEffectResolvesCachedAndQueuedMembers() async throws {
        let fixture = try StoreFixture()
        defer { fixture.close() }
        let rows = [row("a", thread: "thread", date: 30, sender: "Sam"),
                    row("b", thread: "thread", date: 20, sender: "Priya"),
                    row("other", thread: "other", date: 10, sender: "Dana")]
        try await fixture.seed(rows, unread: Set(rows.map(\.id)))
        let queue = makeQueue()
        await queue.adopt(rows, store: fixture.store)
        _ = await queue.applyConfirmedEffects([effect([], complete: false)], store: fixture.store)
        _ = await queue.applyConfirmedEffects([effect([], complete: false)], store: fixture.store)
        let next = await queue.step(.init(), store: fixture.store, dealtWith: false)
        XCTAssertEqual(try current(next.output)["id"] as? String, "other")
        let inbox = await fixture.store.unreadPage(before: nil, limit: 12, account: account)
        XCTAssertEqual(inbox.map(\.id), ["other"])
        await queue.end()
    }

    func testPartialFailureEffectsDoNotInventArchiveAndUndoRestoresInbox() async throws {
        let fixture = try StoreFixture()
        defer { fixture.close() }
        let rows = [row("a", thread: "thread", date: 30, sender: "Sam"),
                    row("b", thread: "thread", date: 20, sender: "Priya")]
        try await fixture.seed(rows, unread: ["a", "b"])
        let queue = makeQueue()
        await queue.adopt(rows, store: fixture.store)
        let labelOnly = await queue.applyConfirmedEffects([effect(["a"], add: ["Label_1"], remove: [])], store: fixture.store)
        XCTAssertNil(labelOnly)
        let stillInbox = await fixture.store.inboxIds(among: ["a", "b"])
        XCTAssertEqual(stillInbox, ["a", "b"])
        _ = await queue.applyConfirmedEffects([effect(["a", "b"]), effect(["a", "b"], add: ["INBOX"], remove: [])], store: fixture.store)
        let restored = await fixture.store.unreadPage(before: nil, limit: 12, account: account)
        XCTAssertEqual(Set(restored.map(\.id)), ["a", "b"])
        let ledger = await queue.dealtWith
        XCTAssertFalse(ledger.contains(LocalTriageQueue.messageKey(account: account, id: "a")))
        await queue.end()
    }

    func testEffectsStayInTheirMailboxAndDoNotAdvanceUnrelatedCursor() async throws {
        let fixture = try StoreFixture()
        defer { fixture.close() }
        let rows = [row("current", thread: "other", date: 30, sender: "Sam"),
                    row("target", thread: "thread", date: 20, sender: "Priya")]
        try await fixture.seed(rows, unread: ["current", "target"])
        let queue = makeQueue()
        await queue.adopt(rows, store: fixture.store)
        let foreign = await queue.applyConfirmedEffects([effect(["current"], mailbox: "other@test")], store: fixture.store)
        XCTAssertNil(foreign)
        let offCursor = await queue.applyConfirmedEffects([effect(["target"])], store: fixture.store)
        XCTAssertNil(offCursor)
        let currentID = await queue.currentId
        XCTAssertEqual(currentID, "current")
        let remaining = await fixture.store.unreadPage(before: nil, limit: 12, account: account)
        XCTAssertEqual(remaining.map(\.id), ["current"])
        await queue.end()
    }

    func testUnreadArchiveRetainsMessageProgressAndPartialUndoRestoresOnlyItsTarget() async throws {
        let fixture = try StoreFixture()
        defer { fixture.close() }
        let rows = [row("a", thread: "thread", date: 30, sender: "Sam"),
                    row("b", thread: "thread", date: 20, sender: "Priya"),
                    row("next", thread: "other", date: 10, sender: "Dana")]
        try await fixture.seed(rows, unread: ["a", "b", "next"])
        try await saveSnapshot(LocalTriageQueue.groupByConversation(rows.map(item)), store: fixture.store)
        let queue = makeQueue()
        _ = await queue.step(.init(scope: .unread), store: fixture.store)
        _ = await queue.applyConfirmedEffects([effect(["a", "b"], remove: ["INBOX", "UNREAD"])], store: fixture.store)
        let next = await queue.step(.init(), store: fixture.store, dealtWith: false)
        XCTAssertEqual(try object(next.output)["position"] as? Int, 3)
        XCTAssertEqual(try current(next.output)["id"] as? String, "next")
        _ = await queue.applyConfirmedEffects([effect(["a"], add: ["INBOX"], remove: [])], store: fixture.store)
        let undone = await queue.step(.init(), store: fixture.store, dealtWith: false)
        XCTAssertEqual(try current(undone.output)["id"] as? String, "a")
        XCTAssertNil(try current(undone.output)["messages"])
        let inbox = await fixture.store.inboxIds(among: ["a", "b"])
        XCTAssertEqual(inbox, ["a"])
        await queue.end()
    }

    func testRestorePublishesAllMembersWithSavedGroupingMode() async throws {
        let fixture = try StoreFixture()
        defer { fixture.close() }
        // One sender: two unread from different people are two stops, so a grouped member
        // list only exists within a sender. See `docs/email-thread-behavior.md`.
        let old = row("old", thread: "thread", date: 10, sender: "Sam")
        let new = row("new", thread: "thread", date: 20, sender: "Sam")
        try await fixture.seed([old, new], unread: ["old", "new"])
        try await saveSnapshot(LocalTriageQueue.groupByConversation([item(old), item(new)]), store: fixture.store)
        let queue = makeQueue()
        let result = await queue.step(.init(scope: .unread), store: fixture.store)
        let payload = try object(result.output)
        let current = try XCTUnwrap(payload["item"] as? [String: Any])
        XCTAssertEqual(result.served, .hit)
        XCTAssertEqual(current["id"] as? String, "new")
        XCTAssertEqual((current["messages"] as? [[String: Any]])?.compactMap { $0["id"] as? String }, ["old", "new"])
        XCTAssertEqual(current["subject"] as? String, "Subject new")
        XCTAssertEqual((current["messages"] as? [[String: Any]])?.compactMap { $0["subject"] as? String },
            ["Subject old", "Subject new"])
        let progress = await queue.progress
        XCTAssertEqual(progress?.queued, 2)
        await queue.end()
    }

    func testGroupedMembersMarkWhichOneTheUserWrote() async throws {
        let fixture = try StoreFixture()
        defer { fixture.close() }
        // The user's own invite must not be credited to the participant its subject names.
        let invite = row("invite", thread: "lunch", date: 10, sender: "Nathaniel Tucker <queue@example.test>",
                         recipient: "Jamie Lane <jamie@school.test>")
        let reply = row("reply", thread: "lunch", date: 20, sender: "Jamie Lane <jamie@school.test>")
        try await fixture.seed([invite, reply], unread: ["invite", "reply"])
        try await saveSnapshot(LocalTriageQueue.groupByConversation([item(invite), item(reply)], grouping: true),
                               store: fixture.store)
        let queue = makeQueue()
        let result = await queue.step(.init(scope: .unread), store: fixture.store)
        let current = try current(result.output)
        let members = try XCTUnwrap(current["messages"] as? [[String: Any]])
        XCTAssertEqual(members.compactMap { $0["id"] as? String }, ["invite", "reply"])
        XCTAssertEqual(members.compactMap { $0["fromMe"] as? Bool }, [true, false])
        XCTAssertEqual(current["fromMe"] as? Bool, false, "The latest member is Jamie's")
        await queue.end()
    }

    func testFromMeMatchesConnectedAddressesNotTheName() {
        let owned = ["kate@example.test", "kate.personal@example.test"]
        XCTAssertTrue(LocalTriageQueue.fromMe("Kate Owner <Kate@Example.test>", accounts: owned))
        XCTAssertTrue(LocalTriageQueue.fromMe("Kate <kate.personal@example.test>", accounts: owned),
                      "Sent from another connected mailbox")
        XCTAssertFalse(LocalTriageQueue.fromMe("Kate Owner <kate@other.test>", accounts: owned))
        XCTAssertFalse(LocalTriageQueue.fromMe("Kate Owner", accounts: owned))
    }

    func testActualUnreadRestoreRetainsSnapshotWhenLabelQueryFails() async throws {
        let fixture = try StoreFixture()
        defer { fixture.close() }
        let rows = [row("old", thread: "thread", date: 10, sender: "Sam"),
                    row("new", thread: "thread", date: 20, sender: "Sam")]
        try await fixture.seed(rows, unread: ["old", "new"])
        try await saveSnapshot(LocalTriageQueue.groupByConversation(rows.map(item)), store: fixture.store)
        try await fixture.database.write { db in
            try db.execute(sql: "DROP TABLE \(MailStore.Label.databaseTableName)")
        }
        let queue = makeQueue()
        let result = await queue.step(.init(scope: .unread), store: fixture.store)
        let restored = try current(result.output)
        XCTAssertEqual(restored["id"] as? String, "new")
        XCTAssertEqual((restored["messages"] as? [[String: Any]])?.compactMap { $0["id"] as? String }, ["old", "new"])
        let progress = await queue.progress
        XCTAssertEqual(progress?.queued, 2)
        await queue.end()
    }

    /// A snapshot checkpointed before this mailbox had bands is thrown away rather than
    /// restored, so the walk opens in band order.
    ///
    /// **Without this the feature cannot turn on for anybody who has already opened a queue
    /// today.** `build` is where the band gate lives, a restore bypasses it, and the snapshot
    /// only rolls over at the local day — which is the state every existing user is in on the
    /// day this ships.
    func testUnstartedUnbandedSnapshotIsDiscardedSoTheWalkOpensInBandOrder() async throws {
        let fixture = try StoreFixture()
        defer { fixture.close() }
        // The high-band message is the OLDER one, so date order and band order disagree and
        // the assertion can tell them apart.
        let rows = [row("newer", thread: "b", date: 20, sender: "Bulk"),
                    row("older", thread: "a", date: 10, sender: "Dana")]
        try await fixture.seed(rows, unread: ["newer", "older"])
        try await saveSnapshot(rows.map(item), store: fixture.store, grouping: false)
        await fixture.store.applyBands(
            ["older": ("high", "needs the contract signed", nil), "newer": ("low", "", nil)],
            account: account)

        let result = await makeQueue().step(.init(scope: .unread), store: fixture.store)
        let current = try current(result.output)
        XCTAssertEqual(current["id"] as? String, "older",
                       "the top band opens the walk, not the newest arrival")
        XCTAssertEqual(current["why"] as? String, "needs the contract signed",
                       "and it carries the reason the model may say")
    }

    /// A *started* unbanded walk is rebuilt too, once the mailbox has bands.
    ///
    /// **This was the opposite assertion until a device run showed what it cost.** Holding a
    /// started walk meant that anyone who had opened a queue that day never saw the ordering
    /// at all — and on the day this ships, that is everybody. It is safe because it can fire
    /// at most once per mailbox: the rebuilt snapshot carries a band, so the condition never
    /// holds again. What is given up is one resume position, once.
    func testAStartedUnbandedSnapshotIsAlsoRebuiltOnceBandsExist() async throws {
        let fixture = try StoreFixture()
        defer { fixture.close() }
        let rows = [row("newest", thread: "c", date: 30, sender: "Bulk"),
                    row("middle", thread: "b", date: 20, sender: "Bulk"),
                    row("older", thread: "a", date: 10, sender: "Dana")]
        try await fixture.seed(rows, unread: ["newest", "middle", "older"])
        // This walk has been started: its first message was acted on.
        var saved = rows.map(item)
        saved[0].acted = "archived"
        try await saveSnapshot(saved, store: fixture.store, grouping: false)
        await fixture.store.applyBands(
            ["older": ("high", "needs the contract signed", nil), "middle": ("low", "", nil), "newest": ("low", "", nil)],
            account: account)

        let result = await makeQueue().step(.init(scope: .unread), store: fixture.store)
        let current = try current(result.output)
        XCTAssertEqual(current["id"] as? String, "older",
                       "the rebuild opens on the top band rather than resuming the date-ordered tail")
        XCTAssertEqual(current["why"] as? String, "needs the contract signed",
                       "and it carries the reason, which a resumed unbanded walk never would")
    }

    /// A banded walk that reaches its end must CLOSE, not report that mail could not be
    /// loaded.
    ///
    /// **This is the device failure of 2026-09-18 and it cost more than a wrong sentence.**
    /// `advance` returns on `stalled` *before* it reaches `nextScopeInPlan`, so a queue that
    /// stalls at the end of the unread walk never crosses into `all` — the user was told
    /// twice that mail could not be loaded, and the read half of their inbox was never
    /// offered at all. The cause was `more` being derived from whether a page had rows
    /// rather than from whether more mail existed; once the buffer held the whole mailbox,
    /// every refill was full of mail already walked and `more` never went false.
    func testABandedWalkClosesRatherThanReportingAStall() async throws {
        let fixture = try StoreFixture()
        defer { fixture.close() }
        let rows = [row("urgent", thread: "a", date: 20, sender: "Dana"),
                    row("bulk", thread: "b", date: 10, sender: "Newsletter")]
        try await fixture.seed(rows, unread: ["urgent", "bulk"])
        await fixture.store.applyBands([
            "urgent": ("high", "needs a reply", 9),
            "bulk": ("low", "", 1),
        ], account: account)

        let queue = makeQueue()
        var last = try object(await queue.step(.init(scope: .unread), store: fixture.store).output)
        var seen: [String] = []
        for _ in 0..<6 {
            if last["done"] as? Bool == true { break }
            if let item = last["item"] as? [String: Any], let id = item["id"] as? String {
                seen.append(id)
            }
            // A stall is the failure under test, so fail loudly rather than looping on it.
            XCTAssertNotEqual(last["loading"] as? Bool, false,
                              "the walk reported that mail could not be loaded: \(last)")
            last = try object(await queue.step(.init(), store: fixture.store).output)
        }

        XCTAssertEqual(seen, ["urgent", "bulk"], "the top band opens the walk and the bulk follows")
        XCTAssertEqual(last["done"] as? Bool, true, "and reaching the end closes the queue")
        await queue.end()
    }

    /// An `all` snapshot does not survive banded unread mail arriving behind it.
    ///
    /// **This blocked every device attempt one evening.** A walk that crosses into `all`
    /// stays there for the rest of the local day, and `all` cannot be banded — it pages live
    /// from Gmail while bands live on cached rows. So finishing an unread pile once silently
    /// ended importance ordering until tomorrow, for exactly the person getting the most out
    /// of it, and new unread mail was served in date order among read mail rather than
    /// walked first.
    func testAnAllSnapshotYieldsToBandedUnreadMail() async throws {
        let fixture = try StoreFixture()
        defer { fixture.close() }
        let rows = [row("urgent", thread: "a", date: 10, sender: "Dana"),
                    row("bulk", thread: "b", date: 20, sender: "Newsletter")]
        try await fixture.seed(rows, unread: ["urgent", "bulk"])
        // A finished review of the whole inbox, checkpointed under `all`.
        try await saveSnapshot(rows.map(item), store: fixture.store, grouping: false, scope: "all")
        await fixture.store.applyBands([
            "urgent": ("high", "needs a reply", 9),
            "bulk": ("low", "", 1),
        ], account: account)

        let result = await makeQueue().step(.init(scope: nil), store: fixture.store)
        let current = try current(result.output)
        XCTAssertEqual(current["id"] as? String, "urgent",
                       "an automatic opening walks the banded unread pile, not the saved `all` review")
        XCTAssertEqual(current["why"] as? String, "needs a reply")
    }

    func testUngroupedRestoreKeepsThreadHintsWithoutCombiningMessages() async throws {
        let fixture = try StoreFixture()
        defer { fixture.close() }
        let rows = [row("new", thread: "thread", date: 20, sender: "Sam"),
                    row("old", thread: "thread", date: 10, sender: "Priya")]
        try await fixture.seed(rows, unread: ["new", "old"])
        try await saveSnapshot(rows.map(item), store: fixture.store, grouping: false)
        let queue = makeQueue()
        let first = await queue.step(.init(scope: .unread), store: fixture.store)
        let firstThread = try XCTUnwrap(object(first.output)["thread"] as? [String: Any])
        XCTAssertEqual(firstThread["queued"] as? Int, 2)
        XCTAssertEqual(firstThread["index"] as? Int, 1)
        XCTAssertEqual(firstThread["continues"] as? Bool, false)
        XCTAssertNil(try current(first.output)["messages"])
        let next = await queue.step(.init(), store: fixture.store, dealtWith: false)
        let nextThread = try XCTUnwrap(object(next.output)["thread"] as? [String: Any])
        XCTAssertEqual(nextThread["index"] as? Int, 2)
        XCTAssertEqual(nextThread["continues"] as? Bool, true)
        XCTAssertEqual(try current(next.output)["id"] as? String, "old")
        await queue.end()
    }

    func testRestoreKeepsSavedGroupingWhenProfileIsDisabled() async throws {
        let fixture = try StoreFixture()
        defer { fixture.close() }
        let old = row("old", thread: "thread", date: 10, sender: "Sam")
        let new = row("new", thread: "thread", date: 20, sender: "Sam")
        try await fixture.seed([old, new], unread: ["old", "new"])
        try await saveSnapshot(LocalTriageQueue.groupByConversation([item(old), item(new)]), store: fixture.store)
        UserDefaults.standard.set(false, forKey: ThreadQueue.storageKey)
        let queue = makeQueue()
        let first = await queue.step(.init(scope: .unread), store: fixture.store)
        let firstItem = try current(first.output)
        XCTAssertEqual(firstItem["id"] as? String, "new")
        XCTAssertEqual((firstItem["messages"] as? [[String: Any]])?.count, 2)
        let finish = await queue.step(.init(), store: fixture.store, dealtWith: false)
        XCTAssertEqual(try object(finish.output)["queued"] as? Int, 2)
        XCTAssertEqual(try object(finish.output)["passed"] as? Int, 2)
    }

    func testRestoreDropsAnOlderMemberReadElsewhereAndRefreshesDraftWarning() async throws {
        let fixture = try StoreFixture()
        defer { fixture.close() }
        let old = row("old", thread: "thread", date: 10, sender: "Sam")
        let new = row("new", thread: "thread", date: 20, sender: "Priya")
        let saved = LocalTriageQueue.groupByConversation([item(old), item(new)])
        try await fixture.seed([old, new], unread: ["new"])
        try await saveSnapshot(saved, store: fixture.store)
        try await fixture.database.write { db in
            try MailStore.Draft(user_id: "test-user", id: "draft", messageId: "draft-message", threadId: "thread",
                account: "queue@example.test", recipient: nil, subject: nil, snippet: nil,
                internalDate: 30, cachedAt: Date()).insert(db)
        }
        let queue = makeQueue()
        let result = await queue.step(.init(scope: .unread), store: fixture.store)
        let mail = try current(result.output)
        XCTAssertEqual(mail["id"] as? String, "new")
        XCTAssertNil(mail["messages"], "The now-read older member must not survive restoration")
        XCTAssertEqual(mail["hasDraft"] as? Bool, true)
        XCTAssertEqual(mail["snippet"] as? String, "Current new")
        let thread = try XCTUnwrap(object(result.output)["thread"] as? [String: Any])
        XCTAssertTrue((thread["note"] as? String)?.contains("unsent draft") == true)
        let progress = await queue.progress
        XCTAssertEqual(progress?.queued, 1)
        await queue.end()
    }

    func testPartialSweepRebuildsFutureConversationAndProtectsCursorAndOtherMailbox() async throws {
        let fixture = try StoreFixture()
        defer { fixture.close() }
        let rows = [
            row("cursor", thread: "current", date: 40, sender: "Priya"),
            row("sweep", thread: "future", date: 30, sender: "Priya"),
            row("keep", thread: "future", date: 20, sender: "Sam"),
            row("other-account", thread: "other", date: 10, sender: "Priya", account: "other@example.test"),
        ]
        try await fixture.seed(rows, unread: Set(rows.map(\.id)))
        let queue = makeQueue()
        await queue.adopt(rows, store: fixture.store)
        let removed = await queue.pruneAhead(senders: [], ids: ["cursor", "sweep", "other-account"], account: account)
        XCTAssertEqual(removed, 1)
        let cursor = await queue.currentId
        XCTAssertEqual(cursor, "cursor")
        let next = await queue.step(.init(), store: fixture.store, dealtWith: false)
        XCTAssertEqual(try current(next.output)["id"] as? String, "keep")
        XCTAssertEqual(try current(next.output)["from"] as? String, "Sam")
        let finish = try object(
            await queue.step(.init(), store: fixture.store, dealtWith: false).output)
        XCTAssertEqual(finish["done"] as? Bool, true)
        XCTAssertEqual(finish["queued"] as? Int, 2)
        XCTAssertEqual(finish["passed"] as? Int, 2)
        XCTAssertNil(finish["item"], "A queue adopted for one mailbox must not cross accounts")
    }

    func testOlderMemberActionAdvancesAndCloseCountsMessagesIncludingReadMail() async throws {
        let fixture = try StoreFixture()
        defer { fixture.close() }
        let rows = [
            row("new", thread: "conversation", date: 30, sender: "Priya"),
            row("old", thread: "conversation", date: 20, sender: "Sam"),
            row("last", thread: "other", date: 10, sender: "Dana"),
        ]
        try await fixture.seed(rows, unread: ["new", "last"])
        let queue = makeQueue()
        await queue.adopt(rows, store: fixture.store)
        let matches = await queue.standingOn(messageId: "old")
        let unrelated = await queue.standingOn(messageId: "last")
        XCTAssertTrue(matches)
        XCTAssertFalse(unrelated)
        await queue.markActed(id: "old", as: "archive_message")
        let next = await queue.step(.init(), store: fixture.store, dealtWith: false)
        XCTAssertEqual(try current(next.output)["id"] as? String, "last")
        let progress = await queue.standing
        XCTAssertEqual(progress?.position, 3)
        XCTAssertEqual(progress?.total, 3)
        let finish = await queue.step(.init(), store: fixture.store, dealtWith: false)
        let totals = try object(finish.output)
        XCTAssertEqual(totals["queued"] as? Int, 3)
        XCTAssertEqual(totals["acted"] as? Int, 2)
        XCTAssertEqual(totals["passed"] as? Int, 1)
    }

    func testImportantSkipStaysSkippedOnALaterWalk() async throws {
        let fixture = try StoreFixture()
        defer { fixture.close() }
        let backend = Container.shared.backend()
        let previousUser = backend.userId
        let user = UUID().uuidString
        backend.userId = user
        defer {
            backend.userId = previousUser
            try? FileManager.default.removeItem(at: DealtWithLog.url(userID: user))
        }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let rows = [row("first", thread: "first", date: now, sender: "Sam"),
                    row("second", thread: "second", date: now - 1000, sender: "Priya")]
        // Skipped on an earlier call: read, and in the ledger.
        try await fixture.seed(rows, unread: ["second"])
        DealtWithLog.save([LocalTriageQueue.messageKey(account: account, id: "first"):
            Date().timeIntervalSince1970], userID: user)

        let queue = makeQueue()
        await queue.configure(coachingPlan: nil,
            forceOnboardingFeedLesson: false, sequentialFeed: false,
            calendarFeedDue: false, localCalendar: false)
        let opening = await queue.step(.init(scope: .important), store: fixture.store)
        XCTAssertEqual(try current(opening.output)["id"] as? String, "second")
        await queue.end()
    }

    func testDraftToPriorMemberDoesNotFinishCurrentContinuation() async throws {
        let fixture = try StoreFixture()
        defer { fixture.close() }
        let older = row("older", thread: "thread", date: 10, sender: "Sam")
        let newer = row("newer", thread: "thread", date: 20, sender: "Priya")
        try await fixture.seed([older, newer], unread: ["older", "newer"])
        try await saveSnapshot([item(older), item(newer)], store: fixture.store)
        let queue = makeQueue()
        _ = await queue.step(.init(scope: .unread), store: fixture.store)
        _ = await queue.step(.init(), store: fixture.store, dealtWith: false)
        let selection = await queue.selectedReplyMessageID("older", account: account)
        let selected = try XCTUnwrap(selection)
        let onSelected = await queue.standingOn(messageId: selected, account: account)
        XCTAssertFalse(onSelected)
        let onThread = await queue.standingOn(threadId: "thread", account: account)
        XCTAssertTrue(onThread)
        let badged = await queue.badgeBehindCursor(id: selected, as: "create_draft", account: account)
        XCTAssertTrue(badged)
        let currentID = await queue.currentId
        XCTAssertEqual(currentID, "newer")
        let result = await queue.step(.init(), store: fixture.store, dealtWith: false)
        XCTAssertEqual(try object(result.output)["acted"] as? Int, 1)
    }

    func testSendToPriorMemberDoesNotFinishCurrentContinuation() async throws {
        let fixture = try StoreFixture()
        defer { fixture.close() }
        let older = row("older", thread: "thread", date: 10, sender: "Sam")
        let newer = row("newer", thread: "thread", date: 20, sender: "Priya")
        try await fixture.seed([older, newer], unread: ["older", "newer"])
        try await saveSnapshot([item(older), item(newer)], store: fixture.store)
        let queue = makeQueue()
        _ = await queue.step(.init(scope: .unread), store: fixture.store)
        _ = await queue.step(.init(), store: fixture.store, dealtWith: false)
        let currentSelection = await queue.completionMessageID(named: nil, thread: "newer", verb: "send_email", account: account)
        XCTAssertEqual(currentSelection, "newer")
        let defaultThread = await queue.completionMessageID(named: nil, thread: "thread", verb: "send_email", account: account)
        XCTAssertNil(defaultThread)
        let selection = await queue.completionMessageID(named: nil, thread: "older", verb: "send_email", account: account)
        let selected = try XCTUnwrap(selection)
        let onSelected = await queue.standingOn(messageId: selected, account: account)
        XCTAssertFalse(onSelected)
        let onThread = await queue.standingOn(threadId: "thread", account: account)
        XCTAssertTrue(onThread)
        let badged = await queue.badgeBehindCursor(id: selected, as: "send_email", account: account)
        XCTAssertTrue(badged)
        let currentID = await queue.currentId
        XCTAssertEqual(currentID, "newer")
        let result = await queue.step(.init(), store: fixture.store, dealtWith: false)
        XCTAssertEqual(try object(result.output)["acted"] as? Int, 1)
    }

    func testRestoreKeepsSurvivingCurrentMemberAheadOfFreshMail() async throws {
        let fixture = try StoreFixture()
        defer { fixture.close() }
        let older = row("older", thread: "thread", date: 10, sender: "Sam")
        let newest = row("newest", thread: "thread", date: 20, sender: "Sam")
        let fresh = row("fresh", thread: "fresh", date: 30, sender: "Dana")
        let tail = row("tail", thread: "tail", date: 5, sender: "Sam")
        try await fixture.seed([older, newest, fresh, tail], unread: ["older", "fresh", "tail"])
        try await saveSnapshot(LocalTriageQueue.groupByConversation([item(older), item(newest), item(tail)]), store: fixture.store)
        let queue = makeQueue()
        let first = await queue.step(.init(scope: .unread), store: fixture.store)
        XCTAssertEqual(try current(first.output)["id"] as? String, "older")
        let second = await queue.step(.init(), store: fixture.store, dealtWith: false)
        XCTAssertEqual(try current(second.output)["id"] as? String, "fresh")
        let third = await queue.step(.init(), store: fixture.store, dealtWith: false)
        XCTAssertEqual(try current(third.output)["id"] as? String, "tail")
        await queue.end()
    }

    func testLateDraftRefreshPreservesKnownDraftOnQueryFailure() async throws {
        let fixture = try StoreFixture()
        defer { fixture.close() }
        let message = row("message", thread: "thread", date: 10, sender: "Sam")
        try await fixture.seed([message], unread: ["message"])
        try await fixture.database.write { db in
            try MailStore.Draft(user_id: "test-user", id: "draft", messageId: "draft-message", threadId: "thread",
                account: "queue@example.test", recipient: nil, subject: nil, snippet: nil,
                internalDate: 20, cachedAt: Date()).insert(db)
        }
        try await saveSnapshot([item(message)], store: fixture.store)
        let queue = makeQueue()
        let first = await queue.step(.init(scope: .unread), store: fixture.store)
        XCTAssertEqual(try current(first.output)["hasDraft"] as? Bool, true)
        try await fixture.database.write { db in try db.execute(sql: "DROP TABLE mail_draft") }
        let failedRefresh = await queue.step(.init(direction: "back"), store: fixture.store)
        XCTAssertEqual(try current(failedRefresh.output)["hasDraft"] as? Bool, true)
        try await fixture.database.write { db in try MailStore.createUserScopedSchema(db) }
        let emptyRefresh = await queue.step(.init(direction: "back"), store: fixture.store)
        XCTAssertNil(try current(emptyRefresh.output)["hasDraft"])
        await queue.end()
    }

    func testThreadWideActionsFinishKnownContinuationsAndKeepOtherMail() async throws {
        for verb in ["archive_message"] {
            let fixture = try StoreFixture()
            defer { fixture.close() }
            let rows = [row("older", thread: "thread", date: 10, sender: "Sam"),
                row("current", thread: "thread", date: 20, sender: "Priya"),
                row("continuation", thread: "thread", date: 30, sender: "Dana"),
                row("other", thread: "other", date: 5, sender: "Sam")]
            try await fixture.seed(rows, unread: Set(rows.map(\.id)))
            try await saveSnapshot(rows.map(item), store: fixture.store)
            let queue = makeQueue()
            _ = await queue.step(.init(scope: .unread), store: fixture.store)
            _ = await queue.step(.init(), store: fixture.store, dealtWith: false)
            let landed = await queue.standingOnAction(messageId: "older", verb: verb, account: account)
            XCTAssertTrue(landed)
            let removed = await queue.unreadRemovalIDs(id: "older", verb: verb, account: account)
            XCTAssertEqual(Set(removed), ["older", "current", "continuation"])
            await queue.markActed(id: "older", as: verb, account: account)
            let next = await queue.step(.init(), store: fixture.store, dealtWith: false)
            XCTAssertEqual(try current(next.output)["id"] as? String, "other")
            let end = await queue.step(.init(), store: fixture.store, dealtWith: false)
            XCTAssertEqual(try object(end.output)["queued"] as? Int, 4)
            XCTAssertEqual(try object(end.output)["acted"] as? Int, 3)
        }
    }

    func testGroupsThreadsReportsTheModeTheWalkCaptured() async throws {
        for grouping in [false, true] {
            let fixture = try StoreFixture()
            defer { fixture.close() }
            let rows = [row("older", thread: "thread", date: 10, sender: "Sam"),
                row("current", thread: "thread", date: 20, sender: "Priya")]
            try await fixture.seed(rows, unread: Set(rows.map(\.id)))
            try await saveSnapshot(rows.map(item), store: fixture.store, grouping: grouping)
            let queue = makeQueue()
            _ = await queue.step(.init(scope: .unread), store: fixture.store)
            let captured = await queue.groupsThreads
            XCTAssertEqual(captured, grouping, "threadQueue \(grouping): the walk reports its saved mode")
        }
    }

    func testHistoricalMessageActionRequeuesUntouchedSiblingAfterCurrent() async throws {
        let fixture = try StoreFixture()
        defer { fixture.close() }
        // One sender on the thread: two would be two stops with no sibling to requeue.
        let a = row("a", thread: "thread", date: 30, sender: "Sam")
        let b = row("b", thread: "thread", date: 20, sender: "Sam")
        let live = row("live", thread: "live", date: 10, sender: "Dana")
        let tail = row("tail", thread: "tail", date: 5, sender: "Sam")
        try await fixture.seed([a, b, live, tail], unread: ["a", "b", "live", "tail"])
        try await saveSnapshot(LocalTriageQueue.groupByConversation([item(a), item(b), item(live), item(tail)]), store: fixture.store)
        let queue = makeQueue()
        _ = await queue.step(.init(scope: .unread), store: fixture.store)
        _ = await queue.step(.init(), store: fixture.store, dealtWith: false)
        let badged = await queue.badgeBehindCursor(id: "a", as: "mark_spam", account: account)
        XCTAssertTrue(badged)
        let currentID = await queue.currentId
        XCTAssertEqual(currentID, "live")
        let next = await queue.step(.init(), store: fixture.store, dealtWith: false)
        XCTAssertEqual(try current(next.output)["id"] as? String, "b")
        XCTAssertNil(try current(next.output)["alreadyDone"])
        _ = await queue.step(.init(), store: fixture.store, dealtWith: false)
        let handled = await queue.coachingHandled
        XCTAssertEqual(handled, 3)
        await queue.end()
    }

    /// The tip cadence counts the account's day, not one mailbox's queue: `end()` is what a
    /// profile switch calls, and it used to hand the destination a fresh count and a free tip.
    func testCoachingCadenceSurvivesTheRebuildAProfileSwitchCauses() async throws {
        let fixture = try StoreFixture()
        defer { fixture.close() }
        let rows = [row("a", thread: "a", date: 30, sender: "Sam"),
            row("b", thread: "b", date: 20, sender: "Dana"),
            row("c", thread: "c", date: 10, sender: "Priya")]
        try await fixture.seed(rows, unread: Set(rows.map(\.id)))
        try await saveSnapshot(rows.map(item), store: fixture.store)
        let queue = makeQueue()
        _ = await queue.step(.init(scope: .unread), store: fixture.store)
        _ = await queue.step(.init(), store: fixture.store, dealtWith: false)
        let walked = await queue.coachingHandled
        XCTAssertEqual(walked, 1)
        await queue.end()
        let afterSwitch = await queue.coachingHandled
        XCTAssertEqual(afterSwitch, walked)
        _ = await queue.step(.init(scope: .unread), store: fixture.store)
        _ = await queue.step(.init(), store: fixture.store, dealtWith: false)
        let afterRebuild = await queue.coachingHandled
        XCTAssertEqual(afterRebuild, 2)
    }

    func testThreadActionCountsAbsorbedContinuationOnlyOnce() async throws {
        let fixture = try StoreFixture()
        defer { fixture.close() }
        let rows = [row("old", thread: "thread", date: 30, sender: "Sam"),
            row("live", thread: "live", date: 20, sender: "Dana"),
            row("continuation", thread: "thread", date: 10, sender: "Priya"),
            row("tail", thread: "tail", date: 5, sender: "Sam")]
        try await fixture.seed(rows, unread: Set(rows.map(\.id)))
        try await saveSnapshot(rows.map(item), store: fixture.store)
        let queue = makeQueue()
        _ = await queue.step(.init(scope: .unread), store: fixture.store)
        _ = await queue.step(.init(), store: fixture.store, dealtWith: false)
        await queue.markActed(id: "old", as: "archive_message", account: account)
        await queue.markActed(id: "old", as: "archive_message", account: account)
        await queue.checkpoint(store: fixture.store)
        let handled = await queue.coachingHandled
        XCTAssertEqual(handled, 2)
        let live = await queue.currentId
        XCTAssertEqual(live, "live")
        let next = await queue.step(.init(), store: fixture.store, dealtWith: false)
        XCTAssertEqual(try current(next.output)["id"] as? String, "tail")
        await queue.end()
    }

    func testRequeuedHistoricalSiblingSurvivesCheckpointAfterNormalSkip() async throws {
        let fixture = try StoreFixture()
        defer { fixture.close() }
        let rows = [row("a", thread: "thread", date: 30, sender: "Sam"),
                    row("b", thread: "thread", date: 20, sender: "Sam"),
                    row("live", thread: "live", date: 10, sender: "Dana")]
        try await fixture.seed(rows, unread: ["a", "b", "live"])
        let queue = makeQueue()
        await queue.adopt(rows, store: fixture.store)
        _ = await queue.step(.init(), store: fixture.store)
        let badged = await queue.badgeBehindCursor(id: "a", as: "mark_spam", account: account)
        XCTAssertTrue(badged)
        let ledger = await queue.dealtWith
        XCTAssertFalse(ledger.contains(LocalTriageQueue.messageKey(account: account, id: "b")))
        await queue.checkpoint(store: fixture.store)
        // The ledger moves with the cursor row, not the item buffer.
        let key = TriageQueueSnapshotStore.key(account: account, day: LocalTriageQueue.localDay(), scope: .all,
                                               split: TriageQueueSnapshotStore.cursorSplit)
        let record = try await fixture.database.read { db in try DailyEmailQueueSnapshotRecord.fetchOne(db, key: key) }
        let payload = try XCTUnwrap(record?.payload)
        let snapshot = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        XCTAssertFalse((snapshot["gmailWalkDealtWith"] as? [String] ?? []).contains(
            LocalTriageQueue.messageKey(account: account, id: "b")))
        await queue.end()
        let resumed = makeQueue()
        _ = await resumed.step(.init(scope: .all), store: fixture.store)
        let next = await resumed.step(.init(), store: fixture.store, dealtWith: false)
        XCTAssertEqual(try current(next.output)["id"] as? String, "b")
        await resumed.end()
    }

    func testStopAndResumeRebasesTheSavedBufferBeforeWritingTheCursor() async throws {
        let fixture = try StoreFixture()
        defer { fixture.close() }
        let rows = [row("a", thread: "a", date: 30, sender: "Sam"),
                    row("b", thread: "b", date: 20, sender: "Dana"),
                    row("c", thread: "c", date: 10, sender: "Lee")]
        try await fixture.seed(rows, unread: Set(rows.map(\.id)))
        let queue = makeQueue()
        _ = await queue.step(.init(scope: .unread), store: fixture.store)
        let second = await queue.step(.init(), store: fixture.store, dealtWith: false)
        XCTAssertEqual(try current(second.output)["id"] as? String, "b")
        _ = await queue.step(.init(stop: true), store: fixture.store)
        let resumed = await queue.step(.init(scope: .unread), store: fixture.store)
        XCTAssertEqual(try current(resumed.output)["id"] as? String, "b")
        let snapshots = try await TriageQueueSnapshotStore.savedToday(
            account: account, userId: fixture.store.userId, database: fixture.database)
        let saved = try XCTUnwrap(snapshots.first)
        XCTAssertEqual(saved.items[saved.position - 1].id, "b")
        await queue.end()
        let reopened = makeQueue()
        let restored = await reopened.step(.init(scope: .unread), store: fixture.store)
        XCTAssertEqual(try current(restored.output)["id"] as? String, "b")
        await reopened.end()
    }

    func testAPlainAdvanceRewritesTheCursorRowAndNotTheItemBuffer() async throws {
        let fixture = try StoreFixture()
        defer { fixture.close() }
        let rows = [row("a", thread: "a", date: 30, sender: "Sam"),
                    row("b", thread: "b", date: 20, sender: "Dana"),
                    row("c", thread: "c", date: 10, sender: "Lee")]
        try await fixture.seed(rows, unread: Set(rows.map(\.id)))
        let queue = makeQueue()
        _ = await queue.step(.init(scope: .unread), store: fixture.store)
        let day = LocalTriageQueue.localDay()
        let bufferKey = TriageQueueSnapshotStore.key(account: account, day: day, scope: .unread, split: "")
        let cursorKey = TriageQueueSnapshotStore.key(account: account, day: day, scope: .unread,
                                                     split: TriageQueueSnapshotStore.cursorSplit)
        func savedRows() async throws -> (buffer: DailyEmailQueueSnapshotRecord, cursor: DailyEmailQueueSnapshotRecord) {
            try await fixture.database.read { db in
                (try XCTUnwrap(DailyEmailQueueSnapshotRecord.fetchOne(db, key: bufferKey)),
                 try XCTUnwrap(DailyEmailQueueSnapshotRecord.fetchOne(db, key: cursorKey)))
            }
        }
        let built = try await savedRows()
        XCTAssertEqual(try JSONDecoder().decode(TriageQueueSnapshotStore.Cursor.self, from: built.cursor.payload).position, 1)

        _ = await queue.step(.init(), store: fixture.store, dealtWith: false)
        let advanced = try await savedRows()
        XCTAssertEqual(advanced.buffer.payload, built.buffer.payload, "A plain advance encodes no item")
        XCTAssertEqual(advanced.buffer.updatedAt, built.buffer.updatedAt, "A plain advance writes no item buffer")
        XCTAssertNotEqual(advanced.cursor.payload, built.cursor.payload)
        XCTAssertEqual(try JSONDecoder().decode(TriageQueueSnapshotStore.Cursor.self, from: advanced.cursor.payload).position, 2)
        // What a restore reads is the two rows together: the second message is current.
        let merged = try await TriageQueueSnapshotStore.savedToday(
            account: account, userId: fixture.store.userId, database: fixture.database)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.position, 2)
        XCTAssertEqual(merged.first?.items.map(\.id), ["a", "b", "c"])
        await queue.end()

        // And the walk resumes on it.
        let resumed = makeQueue()
        let first = await resumed.step(.init(scope: .unread), store: fixture.store)
        XCTAssertEqual(try current(first.output)["id"] as? String, "b")
        await resumed.end()
    }

    func testRequeuedReadSiblingSurvivesUnreadResume() async throws {
        // `important` walks read mail since #982, so a read sibling is in it by definition.
        for scope in [LocalTriageQueue.Scope.unread] {
            let fixture = try StoreFixture()
            defer { fixture.close() }
            let rows = [row("a", thread: "thread", date: 30, sender: "Sam"),
                        row("b", thread: "thread", date: 20, sender: "Sam"),
                        row("live", thread: "live", date: 10, sender: "Dana")]
            try await fixture.seed(rows, unread: ["a", "b", "live"])
            try await fixture.database.write { db in
                try MailStore.createUserScopedSchema(db)
                for id in ["a", "b", "live"] {
                    try MailStore.Label(user_id: "test-user", messageId: id, account: account,
                                        label: "IMPORTANT").insert(db)
                }
            }
            try await saveSnapshot(LocalTriageQueue.groupByConversation(rows.map(item)), store: fixture.store, scope: scope.rawValue)
            let queue = makeQueue()
            _ = await queue.step(.init(scope: scope), store: fixture.store)
            _ = await queue.step(.init(), store: fixture.store)
            await fixture.store.clearUnreadDurably(id: "a", account: account)
            await fixture.store.clearUnreadDurably(id: "b", account: account)
            let unread = await fixture.store.unreadIds(among: ["a", "b"])
            XCTAssertEqual(unread, [])
            let badged = await queue.badgeBehindCursor(id: "a", as: "mark_spam", account: account, store: fixture.store)
            XCTAssertTrue(badged)
            await queue.end()
            let resumed = makeQueue()
            let first = await resumed.step(.init(scope: scope), store: fixture.store)
            XCTAssertEqual(try current(first.output)["id"] as? String, "live")
            let next = await resumed.step(.init(), store: fixture.store, dealtWith: false)
            XCTAssertEqual(try current(next.output)["id"] as? String, "b")
            let progress = await resumed.progress
            XCTAssertGreaterThan(progress?.queued ?? 0, 1)
            await resumed.end()
        }
    }

    func testRevisitedPartialActionPreservesReadSiblingOnResume() async throws {
        let fixture = try StoreFixture()
        defer { fixture.close() }
        let rows = [row("a", thread: "thread", date: 30, sender: "Sam"),
                    row("b", thread: "thread", date: 20, sender: "Sam"),
                    row("live", thread: "live", date: 10, sender: "Dana")]
        try await fixture.seed(rows, unread: ["a", "b", "live"])
        try await fixture.database.write { db in try MailStore.createUserScopedSchema(db) }
        try await saveSnapshot(LocalTriageQueue.groupByConversation(rows.map(item)), store: fixture.store)
        let queue = makeQueue()
        _ = await queue.step(.init(scope: .unread), store: fixture.store)
        _ = await queue.step(.init(), store: fixture.store)
        await fixture.store.clearUnreadDurably(id: "a", account: account)
        await fixture.store.clearUnreadDurably(id: "b", account: account)
        _ = await queue.step(.init(direction: "back"), store: fixture.store, dealtWith: false)
        await queue.markActed(id: "a", as: "mark_spam", account: account)
        let ledger = await queue.dealtWith
        XCTAssertFalse(ledger.contains(LocalTriageQueue.messageKey(account: account, id: "b")))
        _ = await queue.step(.init(), store: fixture.store, dealtWith: false)
        await queue.end()
        let resumed = makeQueue()
        let first = await resumed.step(.init(scope: .unread), store: fixture.store)
        XCTAssertEqual(try current(first.output)["id"] as? String, "b")
        await resumed.end()
    }

    func testLegacyHandledSnapshotDoesNotReintroduceProcessedMail() async throws {
        let fixture = try StoreFixture()
        defer { fixture.close() }
        let handled = row("handled", thread: "handled-thread", date: 30, sender: "Sam")
        let live = row("live", thread: "live-thread", date: 20, sender: "Priya")
        let tail = row("tail", thread: "tail-thread", date: 10, sender: "Dana")
        try await fixture.seed([handled, live, tail], unread: ["handled", "live", "tail"])
        try await saveSnapshot([item(live), item(tail)], store: fixture.store, grouping: nil, handled: ["handled"])
        let queue = makeQueue()
        let first = await queue.step(.init(scope: .unread), store: fixture.store)
        XCTAssertEqual(try current(first.output)["id"] as? String, "live")
        let next = await queue.step(.init(), store: fixture.store, dealtWith: false)
        XCTAssertEqual(try current(next.output)["id"] as? String, "tail")
        await queue.end()
    }

    func testAdoptedExchangesStaySeparateWithoutWholeThreadVerification() async throws {
        for unread in [true, false] {
            let fixture = try StoreFixture()
            defer { fixture.close() }
            var john = row("john", thread: "thread", date: 30, sender: "John")
            john.inReplyTo = "<root@test>"
            john.referenceHeaders = "<root@test>"
            // John's own follow-up rather than a second sender: unread from two people is
            // two stops, and this test is about exchanges, not sender boundaries.
            var secretary = row("secretary", thread: "thread", date: 40, sender: "John")
            secretary.inReplyTo = "<john@test>"
            secretary.referenceHeaders = "<root@test> <john@test>"
            var amy = row("amy", thread: "thread", date: 20, sender: "Amy")
            amy.inReplyTo = "<root@test>"
            amy.referenceHeaders = "<root@test>"
            let unrelated = row("other", thread: "other", date: 10, sender: "Other")
            let rows = [john, secretary, amy, unrelated]
            try await fixture.seed(rows, unread: unread ? Set(rows.map(\.id)) : [])
            let queue = makeQueue()
            await queue.adopt(rows, store: fixture.store)
            let first = await queue.step(.init(direction: "back"), store: fixture.store, dealtWith: false)
            let payload = try object(first.output)
            XCTAssertEqual((payload["thread"] as? [String: Any])?["kind"] as? String,
                           "exchange")
            XCTAssertEqual(try current(first.output)["id"] as? String, "secretary")
            let next = await queue.step(.init(), store: fixture.store, dealtWith: false)
            XCTAssertEqual(try current(next.output)["id"] as? String, "amy")
            XCTAssertEqual((try object(next.output))["position"] as? Int, 3)
            await queue.end()
        }
    }

    private func makeQueue(live: Bool = false) -> LocalTriageQueue {
        LocalTriageQueue(liveFeatures: live, mailAccounts: { ["queue@example.test"] })
    }

    func testExplicitBulkScopePrunesInstacartAndVansDespiteWorkerProse() async throws {
        for (name, sender) in [("Instacart", "no-reply_at_customers_shopemail_com_a1b2c3d4e5_0f0f0f0f@privaterelay.appleid.com"),
                               ("Vans", "vansinfo@email.vans.com")] {
            let fixture = try StoreFixture()
            defer { fixture.close() }
            let rows = [row("source", thread: "source", date: 30, sender: "\(name) <\(sender)>"),
                        row("same-sender", thread: "same-sender", date: 20, sender: "\(name) <\(sender)>"),
                        row("next", thread: "next", date: 10, sender: "Someone else")]
            try await fixture.seed(rows, unread: Set(rows.map(\.id)))
            let queue = makeQueue(live: true)
            await queue.adopt(rows, store: fixture.store)
            let prose = "Archive every inbox email from \(name), using the exact sender represented by message_id: source (account: \(account)). Do not delete or unsubscribe."
            let scope = LocalTriageQueue.DispatchCleanupScope(messageId: "source", query: "in:inbox from:\(sender)")
            let handled = await queue.pruneIfDispatchSweepsSender(task: prose, store: fixture.store,
                account: account, cleanupScope: scope)
            XCTAssertTrue(handled)
            let next = await queue.step(.init(), store: fixture.store, dealtWith: false)
            XCTAssertEqual(try current(next.output)["id"] as? String, "next")
            await queue.end()
        }
    }

    func testExplicitBulkScopeRejectsWrongSourceMailboxAndComplexQueries() {
        let rows = [item(row("source", thread: "source", date: 30, sender: "Vans <vansinfo@email.vans.com>"))]
        for query in ["in:inbox from:other@shop.test", "in:inbox from:email.vans.com",
                      "in:inbox from:vansinfo@email.vans.com older_than:1y",
                      "in:inbox from:vansinfo@email.vans.com OR from:other@shop.test",
                      "in:inbox -from:vansinfo@email.vans.com"] {
            XCTAssertNil(LocalTriageQueue.validatedCleanupQuery(.init(messageId: "source", query: query), account: account, items: rows))
        }
        let valid = LocalTriageQueue.DispatchCleanupScope(messageId: "source", query: "in:inbox from:vansinfo@email.vans.com")
        XCTAssertNil(LocalTriageQueue.validatedCleanupQuery(valid, account: "other@example.test", items: rows))
        XCTAssertNil(LocalTriageQueue.validatedCleanupQuery(.init(messageId: "missing", query: valid.query), account: account, items: rows))
    }

    func testDispatchCompletionIncludesSourceAlreadyBehindCursorWithoutPruning() async throws {
        let fixture = try StoreFixture()
        defer { fixture.close() }
        let rows = [row("source", thread: "source", date: 30, sender: "Instacart"),
                    row("next", thread: "next", date: 20, sender: "Other")]
        try await fixture.seed(rows, unread: Set(rows.map(\.id)))
        try await saveSnapshot(rows.map(item), store: fixture.store)
        let queue = makeQueue(live: true)
        _ = await queue.step(.init(scope: .unread), store: fixture.store)
        let context = await queue.dispatchReconciliation(account: account)
        _ = await queue.step(.init(), store: fixture.store, dealtWith: false)
        _ = await queue.reconcileDispatch(try XCTUnwrap(context), store: fixture.store,
            archivedThreads: { _, threads in Set(threads).intersection(["source"]) })
        let inbox = await fixture.store.inboxIds(among: rows.map(\.id), account: account)
        XCTAssertEqual(inbox, ["next"])
        let currentID = await queue.currentId
        XCTAssertEqual(currentID, "next", "Completion must not advance the cursor again")
        await queue.end()
    }

    func testOpeningVerificationRepairsArchiveWithoutAnyKnownJob() async throws {
        let fixture = try StoreFixture()
        defer { fixture.close() }
        let rows = [row("ghost", thread: "ghost-thread", date: 30, sender: "Vans"),
                    row("next", thread: "next", date: 20, sender: "Other")]
        try await fixture.seed(rows, unread: Set(rows.map(\.id)))
        try await saveSnapshot(rows.map(item), store: fixture.store)
        let queue = makeQueue(live: true)
        let unknown = await queue.archivedCachedItemKeys(in: rows.map(item), store: fixture.store,
            archivedThreads: { _, _ in [] })
        XCTAssertTrue(unknown.isEmpty)
        let removed = await queue.archivedCachedItemKeys(in: rows.map(item), store: fixture.store,
            archivedThreads: { _, _ in ["ghost-thread"] })
        XCTAssertEqual(removed, [LocalTriageQueue.messageKey(account: account, id: "ghost")])
        let result = await queue.step(.init(scope: .unread), store: fixture.store)
        XCTAssertEqual(try current(result.output)["id"] as? String, "next")
        await queue.end()
    }

    func testRealtimePendingArchiveDiscardsCheckpoint() async throws {
        let fixture = try StoreFixture()
        defer { fixture.close() }
        let rows = [row("pending", thread: "pending", date: 30, sender: "Shop")]
        try await fixture.seed(rows, unread: Set(rows.map(\.id)))
        try await saveSnapshot(rows.map(item), store: fixture.store)
        let queue = makeQueue()
        _ = await queue.step(.init(scope: .unread), store: fixture.store)
        _ = await queue.acceptPendingArchive(.init(id: "job", account: account, messageId: "pending", threadId: "pending"))
        await queue.checkpoint(store: fixture.store)
        let records = try await fixture.database.read { db in try DailyEmailQueueSnapshotRecord.fetchAll(db) }
        XCTAssertTrue(records.isEmpty)
        await queue.end()
    }

    func testDeferredArchiveCheckpointSurvivesAndCompletedMailDoesNotReturn() async throws {
        // Exercise first resolution from the queue actor, as on a cold CI launch.
        Container.shared.workspaceProfiles.reset()
        defer { Container.shared.workspaceProfiles.reset() }
        let fixture = try StoreFixture()
        defer { fixture.close() }
        let rows = [row("corelle", thread: "corelle-thread", date: 30, sender: "Corelle"),
                    row("next", thread: "next-thread", date: 20, sender: "Next")]
        try await fixture.seed(rows, unread: Set(rows.map(\.id)))
        try await saveSnapshot(rows.map(item), store: fixture.store)
        let queue = makeQueue(live: true)
        _ = await queue.step(.init(scope: .unread), store: fixture.store)
        let pending = PendingArchive(id: "archive-job", account: account, messageId: "corelle", threadId: nil)
        _ = await queue.acceptPendingArchive(pending)
        _ = await queue.step(.init(), store: fixture.store, dealtWith: false)
        await queue.prepareDailySnapshot(store: fixture.store, liveFeatures: false)
        await queue.checkpoint(store: fixture.store)
        let records = try await fixture.database.read { db in try DailyEmailQueueSnapshotRecord.fetchAll(db) }
        XCTAssertFalse(records.isEmpty, "Pending work must not delete the queue checkpoint")
        await queue.end()

        let resumed = makeQueue()
        await resumed.prepareDailySnapshot(store: fixture.store, liveFeatures: true)
        let prepared = try await fixture.database.read { db in try DailyEmailQueueSnapshotRecord.fetchAll(db) }
        XCTAssertFalse(prepared.isEmpty, "Cold-start Live preparation must preserve pending checkpoints")
        await resumed.reconcileArchives(.init(pending: [], succeeded: [pending]), store: fixture.store,
            archivedThreads: { _, threads in Set(threads) })
        let opening = await resumed.step(.init(scope: .unread), store: fixture.store)
        XCTAssertEqual(try current(opening.output)["id"] as? String, "next")
        let inbox = await fixture.store.inboxIds(among: ["corelle"], account: account)
        XCTAssertEqual(inbox, [])
        await resumed.end()
    }

    func testArchiveReceiptDoesNotOverrideUndoOrTouchAnotherMailbox() async throws {
        let fixture = try StoreFixture()
        defer { fixture.close() }
        let rows = [row("a", thread: "thread", date: 30, sender: "Sam"),
                    row("a", thread: "thread", date: 20, sender: "Sam", account: "other@example.test")]
        try await fixture.seed(rows, unread: ["a"])
        let queue = makeQueue(live: true)
        let receipt = PendingArchive(id: "job", account: account, messageId: "a", threadId: "thread")
        await queue.reconcileArchives(.init(pending: [], succeeded: [receipt]), store: fixture.store,
            archivedThreads: { _, _ in [] })
        let undone = await fixture.store.inboxIds(among: ["a"], account: account)
        XCTAssertEqual(undone, ["a"], "An old receipt cannot override current Gmail membership")
        await queue.reconcileArchives(.init(pending: [], succeeded: [receipt]), store: fixture.store,
            archivedThreads: { _, threads in Set(threads) })
        let other = await fixture.store.inboxIds(among: ["a"], account: "other@example.test")
        XCTAssertEqual(other, ["a"])
        await queue.end()
    }

    func testFailedPendingArchiveIsAvailableAfterResumingCursor() async throws {
        let fixture = try StoreFixture()
        defer { fixture.close() }
        let rows = [row("failed", thread: "failed", date: 30, sender: "Shop"),
                    row("next", thread: "next", date: 20, sender: "Next")]
        try await fixture.seed(rows, unread: Set(rows.map(\.id)))
        try await saveSnapshot(rows.map(item), store: fixture.store)
        let queue = makeQueue(live: true)
        _ = await queue.step(.init(scope: .unread), store: fixture.store)
        _ = await queue.acceptPendingArchive(.init(id: "job", account: account, messageId: "failed", threadId: "failed"))
        _ = await queue.step(.init(), store: fixture.store, dealtWith: false)
        await queue.checkpoint(store: fixture.store)
        await queue.end()
        let resumed = makeQueue(live: true)
        await resumed.reconcileArchives(.init(pending: [], succeeded: []), store: fixture.store)
        let opening = await resumed.step(.init(scope: .unread), store: fixture.store)
        XCTAssertEqual(try current(opening.output)["id"] as? String, "next")
        let retry = await resumed.step(.init(), store: fixture.store, dealtWith: false)
        XCTAssertEqual(try current(retry.output)["id"] as? String, "failed")
        let inbox = await fixture.store.inboxIds(among: ["failed"], account: account)
        XCTAssertEqual(inbox, ["failed"])
        await resumed.end()
    }

    func testGeneratedCleanupPrunesAheadAndKeepsOtherCategory() async throws {
        for action in [EmailCleanupDecision.Action.archive, .unsubscribe] {
            let fixture = try StoreFixture()
            defer { fixture.close() }
            let sender = "Shop <offers@shop.test>"
            let rows = [row("current", thread: "current", date: 30, sender: sender),
                        row("promotion", thread: "promotion", date: 20, sender: sender),
                        row("purchase", thread: "purchase", date: 10, sender: sender)]
            try await fixture.seed(rows, unread: Set(rows.map(\.id)))
            try await fixture.database.write { db in
                for id in ["current", "promotion"] {
                    try MailStore.Label(user_id: "test-user", messageId: id, account: account,
                                        label: "CATEGORY_PROMOTIONS").insert(db)
                }
            }
            let queue = makeQueue(live: true)
            try await saveSnapshot(rows.map(item), store: fixture.store)
            _ = await queue.step(.init(scope: .unread), store: fixture.store)
            let context = await queue.dispatchReconciliation(account: account)
            let input = EmailCleanupInput(account: account, id: "current", from: sender)
            let decision = EmailCleanupDecision(category: .promotions, action: action, senderInboxCount: 5, atLeast: false)
            let dispatch = try XCTUnwrap(EmailCleanupPolicy.cleanupPayload(item: input, decision: decision)?["dispatch"] as? [String: Any])
            let task = try XCTUnwrap(dispatch["task"] as? String)
            let handled = await queue.pruneIfDispatchSweepsSender(task: task, store: fixture.store, account: account)
            XCTAssertTrue(handled)
            let next = await queue.step(.init(), store: fixture.store, dealtWith: false)
            XCTAssertEqual(try current(next.output)["id"] as? String, "purchase")
            let stillInbox = await fixture.store.inboxIds(among: rows.map(\.id), account: account)
            XCTAssertEqual(stillInbox, Set(rows.map(\.id)), "A handoff is not yet a confirmed Gmail mutation")
            _ = await queue.reconcileDispatch(try XCTUnwrap(context), store: fixture.store,
                archivedThreads: { _, threads in Set(threads).intersection(["current", "promotion"]) })
            let reconciled = await fixture.store.inboxIds(among: rows.map(\.id), account: account)
            XCTAssertEqual(reconciled, ["purchase"], "Completion repairs even the rows already pruned from the queue")
            await queue.end()
        }
    }

    private func row(_ id: String, thread: String, date: Int64, sender: String, account: String = "queue@example.test",
                     recipient: String? = nil) -> MailStore.Message {
        .init(user_id: "test-user", id: id, account: account, threadId: thread, sender: sender, recipient: recipient,
            subject: "Subject \(id)", snippet: "Current \(id)", internalDate: date, cachedAt: Date(),
            rfcMessageID: "<\(id)@test>", inReplyTo: "<branch-\(thread)@test>",
            referenceHeaders: "<root-\(thread)@test> <branch-\(thread)@test>")
    }

    private func item(_ row: MailStore.Message) -> LocalTriageQueue.Item {
        .init(account: row.account, id: row.id, threadId: row.threadId, from: row.sender ?? "",
            subject: row.subject ?? "", date: "", snippet: "Stale snippet", internalDate: row.internalDate ?? 0,
            messages: [.init(id: row.id, from: row.sender ?? "", subject: row.subject ?? "", date: "",
                snippet: "Stale snippet", internalDate: row.internalDate ?? 0,
                exchangeID: LocalTriageQueue.exchangeID(messageID: row.id, rfcID: row.rfcMessageID,
                    inReplyTo: row.inReplyTo, references: row.referenceHeaders))])
    }

    func testMessageActionRetainsSiblingsAndUsesMessageOrdinals() async throws {
        let fixture = try StoreFixture()
        defer { fixture.close() }
        let rows = [
            // One sender across the thread, so the three stay one stop and the ordinals
            // count messages rather than stops.
            row("old", thread: "thread", date: 10, sender: "Sam"),
            row("middle", thread: "thread", date: 20, sender: "Sam"),
            row("new", thread: "thread", date: 30, sender: "Sam"),
            row("last", thread: "other", date: 5, sender: "Other"),
        ]
        try await fixture.seed(rows, unread: Set(rows.map(\.id)))
        let queue = makeQueue()
        await queue.adopt(rows, store: fixture.store)
        let initial = await queue.standing
        XCTAssertEqual(initial?.position, 1)
        await queue.markActed(id: "middle", as: "trash_message", account: account)
        await queue.markActed(id: "middle", as: "trash_message", account: account)
        let next = await queue.step(.init(), store: fixture.store, dealtWith: false)
        let remainder = try current(next.output)
        XCTAssertEqual((remainder["messages"] as? [[String: Any]])?.compactMap { $0["id"] as? String }, ["old", "new"])
        XCTAssertEqual(try object(next.output)["position"] as? Int, 2)
        let last = await queue.step(.init(), store: fixture.store, dealtWith: false)
        XCTAssertEqual(try object(last.output)["position"] as? Int, 4)
        let standing = await queue.standing
        XCTAssertEqual(standing?.position, 4)
        let finish = await queue.step(.init(), store: fixture.store, dealtWith: false)
        XCTAssertEqual(try object(finish.output)["acted"] as? Int, 1)
        XCTAssertEqual(try object(finish.output)["passed"] as? Int, 3)
    }

    func testLegacySnapshotRefillsWithoutGrouping() async throws {
        let fixture = try StoreFixture()
        defer { fixture.close() }
        let rows = [row("new", thread: "thread", date: 20, sender: "Sam"),
                    row("old", thread: "thread", date: 10, sender: "Priya")]
        try await fixture.seed(rows, unread: ["new", "old"])
        try await saveSnapshot(rows.map(item), store: fixture.store, grouping: nil)
        let queue = makeQueue()
        let first = await queue.step(.init(scope: .unread), store: fixture.store)
        XCTAssertEqual(try current(first.output)["id"] as? String, "new")
        XCTAssertNil(try current(first.output)["messages"])
        let next = await queue.step(.init(), store: fixture.store, dealtWith: false)
        XCTAssertEqual(try current(next.output)["id"] as? String, "old")
        await queue.end()
    }

    func testRestoreKeepsSameThreadContinuationsSeparate() async throws {
        let fixture = try StoreFixture()
        defer { fixture.close() }
        let rows = [row("new", thread: "thread", date: 20, sender: "Sam"),
                    row("old", thread: "thread", date: 10, sender: "Priya")]
        try await fixture.seed(rows, unread: ["new", "old"])
        try await saveSnapshot(rows.map(item), store: fixture.store)
        let queue = makeQueue()
        let first = await queue.step(.init(scope: .unread), store: fixture.store)
        XCTAssertEqual(try current(first.output)["id"] as? String, "new")
        XCTAssertNil(try current(first.output)["messages"])
        let next = await queue.step(.init(), store: fixture.store, dealtWith: false)
        XCTAssertEqual(try current(next.output)["id"] as? String, "old")
        await queue.end()
    }

    func testUnreadCorrectionStaysInTheSelectedMailbox() async throws {
        let fixture = try StoreFixture()
        defer { fixture.close() }
        let rows = [row("a", thread: "thread", date: 20, sender: "Sam"),
                    row("b", thread: "thread", date: 10, sender: "Priya", account: "other@example.test")]
        try await fixture.seed(rows, unread: ["a", "b"])
        await fixture.store.dropUnread(["a", "b"], account: account)
        let remaining = await fixture.store.unreadIds(among: ["a", "b"])
        XCTAssertEqual(remaining, ["b"])
        await fixture.store.dropUnread(["a"], account: account)
        let retry = await fixture.store.unreadIds(among: ["b"])
        XCTAssertEqual(retry, ["b"])
    }

    func testCleanupDispatchKeepsOtherCategoriesAndMailboxUnread() async throws {
        let fixture = try StoreFixture()
        defer { fixture.close() }
        let rows = [
            row("promotion", thread: "thread", date: 30, sender: "Sam <sam@vendor.test>"),
            row("promotion-two", thread: "thread", date: 25, sender: "Sam <sam@vendor.test>"),
            row("receipt", thread: "thread", date: 20, sender: "Sam <sam@vendor.test>"),
            row("other-mailbox", thread: "thread", date: 10, sender: "Sam <sam@vendor.test>", account: "other@example.test"),
        ]
        try await fixture.seed(rows, unread: Set(rows.map(\.id)))
        try await fixture.database.write { db in
            try MailStore.Label(user_id: "test-user", messageId: "promotion", account: account,
                                label: "CATEGORY_PROMOTIONS").insert(db)
            try MailStore.Label(user_id: "test-user", messageId: "promotion-two", account: account,
                                label: "CATEGORY_PROMOTIONS").insert(db)
            try MailStore.Label(user_id: "test-user", messageId: "receipt", account: account,
                                label: "CATEGORY_PURCHASES").insert(db)
            try MailStore.Label(user_id: "test-user", messageId: "other-mailbox",
                                account: "other@example.test", label: "CATEGORY_PROMOTIONS").insert(db)
        }
        let queue = makeQueue()
        await queue.adopt(rows + [row("promotion", thread: "thread", date: 5, sender: "Sam <sam@vendor.test>", account: "other@example.test")], store: fixture.store)
        let advances = await queue.pruneIfDispatchSweepsSender(
            task: "Archive all from:sam@vendor.test category:promotions in:inbox", store: fixture.store, account: account)
        XCTAssertTrue(advances)
        let selected = await queue.currentId
        XCTAssertEqual(selected, "promotion")
        await queue.markActed(id: "promotion", as: "dispatched", account: account, wholeGroup: true)
        let next = await queue.step(.init(), store: fixture.store, dealtWith: false)
        XCTAssertEqual(try current(next.output)["id"] as? String, "receipt")
        let remainingUnread = await fixture.store.unreadIds(among: ["receipt", "other-mailbox"])
        XCTAssertEqual(remainingUnread, ["receipt", "other-mailbox"])
        let ledger = await queue.dealtWith
        XCTAssertFalse(ledger.contains(LocalTriageQueue.messageKey(account: account, id: "receipt")))
        XCTAssertFalse(ledger.contains(LocalTriageQueue.messageKey(account: "other@example.test", id: "other-mailbox")))
        XCTAssertFalse(ledger.contains(LocalTriageQueue.messageKey(account: "other@example.test", id: "promotion")))
        XCTAssertTrue(ledger.contains(LocalTriageQueue.messageKey(account: account, id: "promotion-two")))
        await queue.end()
    }

    /// A sent message must be introducible without a read: the step carries who it went to,
    /// so "your reply to Dana Whitfield" needs no tool call. Reported 2026-09-09 as "a reply
    /// you wrote… Who was it sent to?"
    func testSentMessageStepCarriesItsRecipient() async throws {
        // Both grouping modes: the recipient rides the step, not the thread grouping.
        for grouping in [true, false] {
            UserDefaults.standard.set(grouping, forKey: ThreadQueue.storageKey)
            let fixture = try StoreFixture()
            defer { fixture.close() }
            let rows = [row("opening", thread: "other", date: 30, sender: "Dana <dana@example.test>"),
                        row("sent", thread: "sent-thread", date: 20, sender: "Josh <josh@kiloforge.test>",
                            recipient: "Dana Whitfield <dana@example.test>")]
            try await fixture.seed(rows, unread: Set(rows.map(\.id)))
            let queue = makeQueue()
            await queue.adopt(rows, store: fixture.store)
            let step = await queue.step(.init(), store: fixture.store, dealtWith: false)
            let payload = try current(step.output)
            XCTAssertEqual(payload["id"] as? String, "sent")
            XCTAssertEqual(payload["to"] as? String, "Dana Whitfield <dana@example.test>",
                           "threadQueue \(grouping): the step names who the sent message went to")
            if let members = payload["messages"] as? [[String: Any]] {
                XCTAssertEqual(members.compactMap { $0["to"] as? String }.count, members.count,
                               "threadQueue \(grouping): every grouped member carries its own recipient")
            }
            await queue.end()
        }
    }

    /// The ambiguity that survives the sender rule, from `docs/email-thread-behavior.md`:
    /// "one participant can send several messages in it. A sender name therefore does not
    /// always identify a single reply. 'Sam's reply' needs a unique selected member; when
    /// there are several, Jo must resolve which message is intended." Two senders are two
    /// stops, so the case left is one sender with more than one reply on the stop.
    func testMessageDispatchRetainsGroupAndHandsOffEveryReply() async throws {
        let fixture = try StoreFixture()
        defer { fixture.close() }
        let rows = [row("new", thread: "thread", date: 20, sender: "Sam <sam@one.test>"),
                    row("old", thread: "thread", date: 10, sender: "Sam <sam@one.test>")]
        try await fixture.seed(rows, unread: ["new", "old"])
        let queue = makeQueue()
        await queue.adopt(rows, store: fixture.store)
        let advances = await queue.pruneIfDispatchSweepsSender(
            task: "Forward Sam's reply", store: fixture.store, account: account)
        XCTAssertFalse(advances)
        let handoff = await queue.standingOnJSON
        let payload = try object(XCTUnwrap(handoff))
        let members = try XCTUnwrap(payload["messages"] as? [[String: String]])
        XCTAssertEqual(members.map { $0["id"] }, ["old", "new"])
        XCTAssertEqual(members.first?["from"], "Sam <sam@one.test>")
        XCTAssertNotNil(payload["selectionNote"])
        let unread = await fixture.store.unreadIds(among: ["new", "old"])
        XCTAssertEqual(unread, ["new", "old"])
        let ledger = await queue.dealtWith
        XCTAssertFalse(ledger.contains(LocalTriageQueue.messageKey(account: account, id: "new")))
        await queue.end()
    }

    func testUnresolvedBatchCanAdvanceWithoutFinishingThreadMembers() async throws {
        let fixture = try StoreFixture()
        defer { fixture.close() }
        // One sender, so the stop holds both members; "them" still names nobody, so the
        // sweep's scope cannot be resolved and the queue advances unbadged anyway.
        let rows = [row("new", thread: "thread", date: 30, sender: "Sam <sam@one.test>"),
                    row("old", thread: "thread", date: 20, sender: "Sam <sam@one.test>"),
                    row("next", thread: "next-thread", date: 10, sender: "Alex")]
        try await fixture.seed(rows, unread: Set(rows.map(\.id)))
        let queue = makeQueue()
        await queue.adopt(rows, store: fixture.store)
        // A negated term cannot be read as positive sender membership, so the scope stays
        // unresolved even though the stop has one sender. "from them" would resolve now.
        let resolved = await queue.pruneIfDispatchSweepsSender(
            task: "Archive all -from:sam@one.test", store: fixture.store, account: account)
        XCTAssertFalse(resolved)
        let captured = await queue.standingOnJSON
        let handoff = try XCTUnwrap(captured)
        let next = await queue.step(.init(direction: "next"), store: fixture.store, dealtWith: false)
        XCTAssertEqual(try current(next.output)["id"] as? String, "next")
        let members = try XCTUnwrap(try object(handoff)["messages"] as? [[String: String]])
        XCTAssertEqual(Set(members.compactMap { $0["id"] }), ["new", "old"])
        let unread = await fixture.store.unreadIds(among: ["new", "old"])
        XCTAssertEqual(unread, ["new", "old"])
        let ledger = await queue.dealtWith
        for id in ["new", "old"] {
            XCTAssertFalse(ledger.contains(LocalTriageQueue.messageKey(account: account, id: id)))
        }
        await queue.end()
    }

    /// `docs/email-thread-behavior.md`, from the recording: "changing sender does not itself
    /// create a new group", so two unread on one chain are one stop whoever wrote them, and
    /// "next" leaves the whole conversation rather than stepping through its messages.
    func testUnreadFromDifferentSendersStayOneStop() async throws {
        let fixture = try StoreFixture()
        defer { fixture.close() }
        let chain = [row("sam", thread: "thread", date: 30, sender: "Sam <sam@one.test>"),
                     row("priya", thread: "thread", date: 20, sender: "Priya <priya@two.test>")]
        try await fixture.seed(chain, unread: Set(chain.map(\.id)))
        let queue = makeQueue()
        await queue.adopt(chain, store: fixture.store)
        let held = await queue.currentId
        XCTAssertEqual(held, "sam", "named by its latest reply")
        let alsoHeld = await queue.standingOn(messageId: "priya")
        XCTAssertTrue(alsoHeld, "the other sender's reply is on the same stop")
        let finish = await queue.step(.init(direction: "next"), store: fixture.store, dealtWith: true)
        XCTAssertEqual(try object(finish.output)["done"] as? Bool, true,
                       "next leaves the conversation rather than stepping into it")
        await queue.end()

        let meta = "Meta for Business <advertise-noreply@facebook.com>"
        let same = [row("new", thread: "solo", date: 30, sender: meta, account: account),
                    row("old", thread: "solo", date: 20, sender: meta, account: account)]
        try await fixture.seed(same, unread: Set(same.map(\.id)))
        let merger = makeQueue()
        await merger.adopt(same, store: fixture.store)
        let sameSenderHead = await merger.currentId
        XCTAssertEqual(sameSenderHead, "new")
        let members = await merger.standingOn(messageId: "old")
        XCTAssertTrue(members, "One sender across the thread stays one stop holding both members")
        await merger.end()
    }

    /// A stop holding several replies cannot resolve a specific-reply task — whoever wrote
    /// them — because "when there are several, Jo must resolve which message is intended".
    /// It advances unbadged rather than waiting, so the walk carries on either way.
    func testSeveralRepliesOnOneStopDoNotResolveADispatchTarget() async throws {
        let fixture = try StoreFixture()
        defer { fixture.close() }
        let meta = "Meta for Business <advertise-noreply@facebook.com>"
        let same = [row("new", thread: "thread", date: 30, sender: meta),
                    row("old", thread: "thread", date: 20, sender: meta),
                    row("next", thread: "next-thread", date: 10, sender: "Alex")]
        try await fixture.seed(same, unread: Set(same.map(\.id)))
        let queue = makeQueue()
        await queue.adopt(same, store: fixture.store)
        let resolved = await queue.pruneIfDispatchSweepsSender(
            task: "Archive this one", store: fixture.store, account: account)
        XCTAssertFalse(resolved, "two of one sender's replies cannot name which one")
        await queue.end()

        let mixed = [row("m-new", thread: "m", date: 30, sender: "Sam <sam@one.test>"),
                     row("m-old", thread: "m", date: 20, sender: "Priya <priya@two.test>")]
        try await fixture.seed(mixed, unread: Set(mixed.map(\.id)))
        let second = makeQueue()
        await second.adopt(mixed, store: fixture.store)
        let stops = await second.progress?.queued
        XCTAssertEqual(stops, 2, "both replies are on one stop, counted as two messages")
        let mixedResolves = await second.pruneIfDispatchSweepsSender(
            task: "Archive this one", store: fixture.store, account: account)
        XCTAssertFalse(mixedResolves, "and neither of them is named by 'this one'")
        await second.end()
    }

    func testSingleMessageDispatchAdvancesOnlyItsMailbox() async throws {
        let fixture = try StoreFixture()
        defer { fixture.close() }
        let queue = makeQueue()
        await queue.adopt([row("one", thread: "thread", date: 20, sender: "Sam")], store: fixture.store)
        let own = await queue.pruneIfDispatchSweepsSender(
            task: "Forward this reply", store: fixture.store, account: account)
        let other = await queue.pruneIfDispatchSweepsSender(
            task: "Forward this reply", store: fixture.store, account: "other@example.test")
        XCTAssertTrue(own)
        XCTAssertFalse(other)
        await queue.end()
    }

    func testAmbiguousCleanupDoesNotChangeCurrentGroup() async throws {
        let fixture = try StoreFixture()
        defer { fixture.close() }
        // One sender, so there is still a group for an ambiguous query to leave alone.
        let rows = [row("new", thread: "thread", date: 20, sender: "Sam <sam@one.test>"),
                    row("old", thread: "thread", date: 10, sender: "Sam <sam@one.test>")]
        try await fixture.seed(rows, unread: ["new", "old"])
        let queue = makeQueue()
        await queue.adopt(rows, store: fixture.store)
        // "from them" is no longer ambiguous on a one-sender stop; these three stay
        // unsupported for local pruning — an unknown term, a negation, and a disjunction.
        for task in ["Archive all from:sam@one.test older_than:1y",
                     "Archive all -from:sam@one.test", "Archive all from:sam@one.test OR from:other.test"] {
            let advances = await queue.pruneIfDispatchSweepsSender(task: task, store: fixture.store)
            XCTAssertFalse(advances)
        }
        let standing = await queue.currentId
        XCTAssertEqual(standing, "new")
        let unread = await fixture.store.unreadIds(among: ["new", "old"])
        XCTAssertEqual(unread, ["new", "old"])
        let progress = await queue.progress
        XCTAssertEqual(progress?.queued, 2)
        let ledger = await queue.dealtWith
        XCTAssertFalse(ledger.contains(LocalTriageQueue.messageKey(account: account, id: "new")))
        await queue.end()
    }

    func testImplicitFinishUsesCurrentMailboxWhenRawIDsOverlap() async throws {
        let fixture = try StoreFixture()
        defer { fixture.close() }
        let queue = makeQueue()
        let rows = [row("same", thread: "thread", date: 20, sender: "Sam"),
                    row("same", thread: "thread", date: 10, sender: "Priya", account: "other@example.test")]
        await queue.adopt(rows, store: fixture.store)
        let finished = await queue.markCurrentActed(as: "create_calendar_event")
        XCTAssertEqual(finished, "same")
        let ledger = await queue.dealtWith
        XCTAssertTrue(ledger.contains(LocalTriageQueue.messageKey(account: account, id: "same")))
        XCTAssertFalse(ledger.contains(LocalTriageQueue.messageKey(account: "other@example.test", id: "same")))
        await queue.end()
    }

    func testOffQueueActionResolvesCachedMailboxWithoutMovingCursor() async throws {
        let fixture = try StoreFixture()
        defer { fixture.close() }
        let live = row("live", thread: "live-thread", date: 20, sender: "Sam")
        let outside = row("outside", thread: "outside-thread", date: 10, sender: "Priya")
        try await fixture.seed([live, outside], unread: ["live", "outside"])
        let queue = makeQueue()
        await queue.adopt([live], store: fixture.store)
        let mailbox = await queue.actionAccount(messageId: "outside", threadId: nil, account: nil, store: fixture.store)
        XCTAssertEqual(mailbox, account)
        let landed = await queue.standingOnAction(messageId: "outside", verb: "trash_message", account: account)
        XCTAssertFalse(landed)
        let ids = await queue.unreadRemovalIDs(id: "outside", verb: "trash_message", account: account)
        await fixture.store.dropUnread(ids, account: mailbox)
        let unread = await fixture.store.unreadIds(among: ["live", "outside"])
        XCTAssertEqual(unread, ["live"])
        let currentID = await queue.currentId
        XCTAssertEqual(currentID, "live")
        await queue.end()
    }

    func testMailboxSwitchRestoresEachIndependentCursorWithoutAdvancing() async throws {
        let fixture = try StoreFixture()
        defer { fixture.close() }
        let work = "work@example.test"
        let personal = "personal@example.test"
        let workRow = row(
            "work-current", thread: "work-thread", date: 20, sender: "Sam", account: work)
        let personalRow = row(
            "personal-current", thread: "personal-thread", date: 10, sender: "Priya", account: personal)
        try await fixture.seed([workRow, personalRow], unread: [workRow.id, personalRow.id])
        try await saveSnapshot([item(workRow)], store: fixture.store, mailbox: work)
        try await saveSnapshot([item(personalRow)], store: fixture.store, mailbox: personal)

        let queue = LocalTriageQueue(mailAccounts: { [work, personal] })
        let opened = await queue.step(.init(scope: .unread, account: work), store: fixture.store)
        XCTAssertEqual(try current(opened.output)["id"] as? String, workRow.id)
        XCTAssertEqual((try object(opened.output))["account"] as? String, work)

        let reselected = await queue.step(.init(account: work), store: fixture.store)
        XCTAssertEqual(try current(reselected.output)["id"] as? String, workRow.id)
        XCTAssertEqual((try object(reselected.output))["position"] as? Int, 1)

        let switched = await queue.step(.init(account: personal), store: fixture.store)
        XCTAssertEqual(try current(switched.output)["id"] as? String, personalRow.id)
        XCTAssertEqual((try object(switched.output))["account"] as? String, personal)

        let jobID = UUID()
        let held = await queue.hold(.init(
            jobId: jobID, task: "Summarize Sam's message", text: "Sam needs a reply.",
            ok: true, expects: .answer,
            about: .init(
                account: work, id: workRow.id, threadId: workRow.threadId,
                from: workRow.sender ?? "", subject: workRow.subject ?? "")))
        XCTAssertTrue(held)
        let released = await queue.release(jobId: jobID)
        XCTAssertEqual(released?.jobId, jobID)

        let returned = await queue.step(.init(account: work), store: fixture.store)
        XCTAssertEqual(try current(returned.output)["id"] as? String, workRow.id)
        XCTAssertEqual((try object(returned.output))["position"] as? Int, 1)

        let handoff = try object(
            await queue.step(.init(), store: fixture.store, dealtWith: false).output)
        XCTAssertEqual(handoff["account"] as? String, work)

        let declined = try object(await queue.step(.init(stop: true), store: fixture.store).output)
        XCTAssertEqual(declined["stopped"] as? Bool, true)
        XCTAssertTrue((declined["note"] as? String)?.contains("queue is closed") == true)
        await queue.end()
    }

    func testMixedRecentResultsAdoptOnlyTheSelectedMailbox() async throws {
        let fixture = try StoreFixture()
        defer { fixture.close() }
        let work = "work@example.test"
        let personal = "personal@example.test"
        let workRow = row("work", thread: "work-thread", date: 20, sender: "Sam", account: work)
        let personalRow = row(
            "personal", thread: "personal-thread", date: 10, sender: "Priya", account: personal)
        try await fixture.seed([workRow, personalRow], unread: [workRow.id, personalRow.id])

        let queue = LocalTriageQueue(mailAccounts: { [work, personal] })
        await queue.adopt([workRow, personalRow], account: personal, store: fixture.store)
        let progress = await queue.progress
        XCTAssertEqual(progress?.account, personal)
        XCTAssertEqual(progress?.queued, 1)
        let currentID = await queue.currentId
        XCTAssertEqual(currentID, personalRow.id)
        await queue.end()
    }

    func testDestinationCandidatesUseImportanceOrderWithoutChangingTheQueue() async throws {
        let fixture = try StoreFixture()
        defer { fixture.close() }
        let rows = [row("normal", thread: "n", date: 30, sender: "Sender"),
                    row("urgent", thread: "u", date: 10, sender: "Sender"),
                    row("other", thread: "o", date: 40, sender: "Sender", account: "other@example.test")]
        try await fixture.seed(rows, unread: Set(rows.map(\.id)))
        await fixture.store.applyBands(["urgent": ("high", "reply", 9)], account: account)
        let queue = makeQueue()
        await queue.adopt([rows[0]], store: fixture.store)
        let before = await queue.currentId
        let keys = await LocalTriageQueue.openingPreparationCandidates(
            account: account, store: fixture.store, grouping: false)
        let after = await queue.currentId
        XCTAssertEqual(keys.map(\.messageId), ["urgent", "normal"])
        XCTAssertTrue(keys.allSatisfy { $0.account == account })
        XCTAssertEqual(before, after)
        let unread = await fixture.store.unreadIds(among: rows.map(\.id))
        XCTAssertEqual(unread, Set(rows.map(\.id)))
        await queue.end()
    }

    func testDestinationCandidatesIncludeSavedPositionAndRejectArchivedSelections() async throws {
        let fixture = try StoreFixture()
        defer { fixture.close() }
        let rows = [row("first", thread: "a", date: 30, sender: "Sender"),
                    row("saved", thread: "b", date: 20, sender: "Sender"),
                    row("archived", thread: "c", date: 10, sender: "Sender")]
        try await fixture.seed(rows, unread: Set(rows.map(\.id)))
        try await saveSnapshot(rows.map(item), store: fixture.store, position: 2)
        try await fixture.database.write { db in
            try db.execute(sql: "DELETE FROM mail_message_label WHERE messageId = ? AND label = 'INBOX'", arguments: ["archived"])
        }
        let keys = await LocalTriageQueue.openingPreparationCandidates(
            account: account, store: fixture.store, grouping: false)
        XCTAssertEqual(keys.first?.messageId, "saved")
        XCTAssertFalse(keys.contains { $0.messageId == "archived" })
    }

    func testRefillNotifiesPreparationAfterQueueTeardownAndReopening() async throws {
        let fixture = try StoreFixture()
        defer { fixture.close() }
        UserDefaults.standard.set(false, forKey: ThreadQueue.storageKey)
        let rows = (1...30).map {
            row("mail-\($0)", thread: "thread-\($0)", date: Int64(1000 - $0), sender: "Sender")
        }
        try await fixture.seed(rows, unread: Set(rows.map(\.id)))
        try await fixture.database.write { db in
            try MailStore.SyncState(user_id: "test-user", account: self.account, historyId: "1",
                                    lastSyncedAt: Date(), backfillPageToken: nil, backfillDone: nil,
                                    inboxUnread: rows.count).insert(db)
        }
        let queue = makeQueue()
        let firstRefill = expectation(description: "first queue refill")
        firstRefill.assertForOverFulfill = false
        await queue.configure(
            coachingPlan: nil,
            forceOnboardingFeedLesson: false, sequentialFeed: false,
            calendarFeedDue: false, localCalendar: false,
            preparationChanged: { firstRefill.fulfill() })
        // Profile switching ends and reopens the queue without configuring a new call.
        await queue.end()
        _ = await queue.step(.init(scope: .unread), store: fixture.store)
        for _ in 0..<8 {
            _ = await queue.step(.init(), store: fixture.store, dealtWith: false)
        }
        await fulfillment(of: [firstRefill], timeout: 3)
        let candidates = await queue.emailPreparationCandidates()
        XCTAssertEqual(candidates.count, LocalTriageQueue.preparationReadAhead)
        XCTAssertTrue(candidates.allSatisfy { $0.account == account })
        await queue.end()
    }

    func testMailboxScopedSearchNarrationNamesOnlyTheSelectedMailbox() async throws {
        let mailbox = "personal@example.test"
        let message = row(
            "personal", thread: "personal-thread", date: 10, sender: "Priya", account: mailbox)
        let result = MailSearch.Result(
            messages: [message], account: mailbox, unread: [message.id], totalUnread: 4,
            servedLive: false, liveChecked: false, ms: 1)
        let rendered = MailSearch.formatted(result, query: "", count: 1)
        XCTAssertTrue(rendered.contains("in \(mailbox)"))
        XCTAssertFalse(rendered.contains("across every mailbox"))
    }

    func testSearchMailboxValidationCanonicalizesAndRejectsBeforeCacheRead() async {
        let queue = LocalTriageQueue(mailAccounts: {
            ["Work@Example.test", "personal@example.test"]
        })
        let canonical = await queue.connectedMailbox(named: " work@example.TEST ")
        let missing = await queue.connectedMailbox(named: "old@example.test")
        XCTAssertEqual(canonical, "Work@Example.test")
        XCTAssertNil(missing)
    }

    func testUnverifiedSelectedMailboxSearchRequiresBrokerFallback() {
        let mailbox = "personal@example.test"
        let result = MailSearch.Result(
            messages: [], account: mailbox, unread: [], totalUnread: nil,
            servedLive: false, liveChecked: false, ms: 1)
        for count in [nil, 3] as [Int?] {
            let rendered = MailSearch.formatted(result, query: "", count: count)
            XCTAssertTrue(rendered.contains("gmail_search_messages"))
            XCTAssertTrue(rendered.contains(mailbox))
            XCTAssertFalse(rendered.contains("No mail in the inbox."))
            XCTAssertFalse(rendered.contains("Nothing new in the last day."))
        }
    }

    private func saveSnapshot(_ items: [LocalTriageQueue.Item], store: MailStore, grouping: Bool? = true,
                              handled: [String] = [], scope: String = "unread",
                              scopePlan: [String] = [],
                              mailbox: String? = nil, position: Int = 1, band: String? = nil) async throws {
        let mailbox = mailbox ?? account
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(items))
        var value: [String: Any] = [
            "items": encoded, "accounts": [mailbox], "position": position, "more": false,
            "total": items.count, "mailboxUnreadAtStart": items.count, "scope": scope,
            "scopeUnsaid": false,
            "scopePlan": scopePlan, "adopted": false, "completed": false,
            "gmailWalkDealtWith": handled,
        ]
        if let grouping { value["grouping"] = grouping }
        if let band { value["band"] = band }
        let payload = try JSONSerialization.data(withJSONObject: value)
        let key = [mailbox.lowercased(), LocalTriageQueue.localDay(), scope, ""].joined(separator: "|")
        let record = DailyEmailQueueSnapshotRecord(key: key, account: mailbox,
            localDay: LocalTriageQueue.localDay(), scope: scope, split: "", payload: payload, updatedAt: Date(),
            userId: store.userId)
        try await store.database!.write { db in try record.insert(db) }
    }

    private func object(_ output: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
    }

    private func current(_ output: String) throws -> [String: Any] {
        try XCTUnwrap(object(output)["item"] as? [String: Any])
    }

    /// Hands out `results` in order, then empty batches, counting each read.
    private final class LoaderCalls: @unchecked Sendable {
        private let lock = NSLock()
        private var results: [[MailStore.Ingest]?]
        private var calls = 0
        init(results: [[MailStore.Ingest]?]) { self.results = results }
        var count: Int { lock.withLock { calls } }
        func next() -> [MailStore.Ingest]? {
            lock.withLock {
                calls += 1
                return results.isEmpty ? [] : results.removeFirst()
            }
        }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !condition() {
            guard Date() < deadline else { return XCTFail("Timed out waiting for the read ahead") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private final class AccountsBox: @unchecked Sendable {
        var accounts: [String]
        init(_ accounts: [String]) { self.accounts = accounts }
    }

    /// A profile switch narrows the device grants to the destination's inboxes and resets
    /// the queue. The dropped account selection must not steer the next opening back to
    /// the previous profile's mailbox, which the broker's mailbox guard turns into an
    /// unrecoverable ask-loop.
    func testProfileSwitchDropsThePreviousAccountSelection() async throws {
        let fixture = try StoreFixture()
        defer { fixture.close() }
        // A stored Unread scope keeps the destination walk on the seeded cache; the
        // automatic scope plan opens with a live Important probe this test cannot answer.
        let previousScope = UserDefaults.standard.string(forKey: TriageScope.storageKey)
        TriageScope.store(.unread)
        defer {
            if let previousScope { UserDefaults.standard.set(previousScope, forKey: TriageScope.storageKey) }
            else { UserDefaults.standard.removeObject(forKey: TriageScope.storageKey) }
        }
        let backend = Container.shared.backend()
        let previousUser = backend.userId
        backend.userId = "test-user"
        defer { backend.userId = previousUser }
        let personal = row("p1", thread: "pt", date: 30, sender: "Personal Pat", account: "personal@example.test")
        let work = row("w1", thread: "wt", date: 20, sender: "Work Wes", account: "work@example.test")
        try await fixture.seed([personal, work], unread: ["p1", "w1"])
        try await fixture.database.write { db in
            for account in ["personal@example.test", "work@example.test"] {
                try MailStore.SyncState(user_id: "test-user", account: account, historyId: "1",
                                        lastSyncedAt: Date(), backfillPageToken: nil, backfillDone: nil).insert(db)
            }
        }
        let grants = AccountsBox(["personal@example.test"])
        let queue = LocalTriageQueue(mailAccounts: { grants.accounts })
        await queue.configure(coachingPlan: nil,
            forceOnboardingFeedLesson: false, sequentialFeed: false, calendarFeedDue: false, localCalendar: false)
        let opening = await queue.openingStep(store: fixture.store)
        XCTAssertEqual(try current(opening.output)["id"] as? String, "p1")
        grants.accounts = ["work@example.test"]
        await queue.end()
        let next = await queue.openingStep(store: fixture.store)
        XCTAssertEqual(try current(next.output)["id"] as? String, "w1",
                       "the opening after a switch serves the destination profile's inbox")
        XCTAssertFalse(next.output.contains("personal@example.test"))
        await queue.end()
    }

    /// Landing on the last message must not close the walk. Reported from a two-message
    /// inbox: the step presenting the second said "you've been through your whole inbox"
    /// and the message was never read out.
    func testLandingOnTheLastMessageDoesNotClaimTheWalkIsFinished() async throws {
        let fixture = try StoreFixture()
        defer { fixture.close() }
        let rows = [row("first", thread: "ft", date: 30, sender: "Sam"),
                    row("second", thread: "st", date: 20, sender: "Priya")]
        try await fixture.seed(rows, unread: ["first", "second"])
        // Gmail's own counter, so the cache settles the first page and the walk can end.
        try await fixture.database.write { db in
            try MailStore.SyncState(user_id: "test-user", account: self.account, historyId: "1",
                                    lastSyncedAt: Date(), backfillPageToken: nil, backfillDone: nil,
                                    inboxUnread: rows.count).insert(db)
        }
        // Ungrouped: thread grouping sends an uncached ancestry to Gmail, and the phone in a
        // test has no grant, which leaves the page open and `last` unreachable.
        UserDefaults.standard.set(false, forKey: ThreadQueue.storageKey)
        let queue = makeQueue()
        // Named rather than the daily walk: a saved scope plans `unread → all`, and `last`
        // is deliberately withheld while a stage is still to come.
        let opening = await queue.step(.init(scope: .unread), store: fixture.store)
        XCTAssertEqual(try current(opening.output)["id"] as? String, "first")
        XCTAssertNil(try object(opening.output)["last"])

        let landing = await queue.step(.init(), store: fixture.store, dealtWith: true)
        let payload = try object(landing.output)
        XCTAssertEqual(try current(landing.output)["id"] as? String, "second")
        XCTAssertEqual(payload["last"] as? Bool, true)
        XCTAssertNotEqual(payload["done"] as? Bool, true, "the last message is presented, not closed")
        let says = try XCTUnwrap(payload["lastIsForSaying"] as? String)
        XCTAssertTrue(says.contains("NOT DEALT WITH YET"),
                      "the step must say the message is still being stood on")
        for close in ["Say they have been through", "Say that's their inbox clear",
                      "Say their important mail is done"] {
            XCTAssertFalse(says.contains(close),
                           "landing on the last message must not instruct a close: \(close)")
        }

        let closing = await queue.step(.init(), store: fixture.store, dealtWith: true)
        XCTAssertEqual(try object(closing.output)["done"] as? Bool, true)
        XCTAssertTrue(try XCTUnwrap(object(closing.output)["note"] as? String).contains("inbox clear"),
                      "the close still arrives, on the turn after")
        await queue.end()
    }

    func testBackCrossesFromUnreadToTheLastImportantMessage() async throws {
        let fixture = try StoreFixture()
        defer { fixture.close() }
        let previousScope = UserDefaults.standard.string(forKey: TriageScope.storageKey)
        // **Chosen explicitly**, so the saved `important → unread → all` plan matches whatever
        // the automatic start is.
        TriageScope.store(.important)
        defer {
            if let previousScope { UserDefaults.standard.set(previousScope, forKey: TriageScope.storageKey) }
            else { TriageScope.clear() }
        }
        // This week, so it is in the important scope; the unread row is older than the week.
        let important = row("important", thread: "important-thread",
                            date: Int64(Date().timeIntervalSince1970 * 1000), sender: "Priya")
        let unread = row("unread", thread: "unread-thread", date: 10, sender: "Sam")
        try await fixture.seed([important, unread], unread: ["important", "unread"])
        try await fixture.database.write { db in
            try MailStore.Label(user_id: "test-user", messageId: important.id, account: account,
                                label: "IMPORTANT").insert(db)
            try MailStore.SyncState(user_id: "test-user", account: account, historyId: "1",
                                    lastSyncedAt: Date(), backfillPageToken: nil, backfillDone: nil,
                                    inboxUnread: 2).insert(db)
        }
        try await saveSnapshot([item(important)], store: fixture.store, scope: "important",
                               scopePlan: ["important", "unread", "all"], band: "high")
        let queue = makeQueue()

        let opening = await queue.step(.init(), store: fixture.store)
        XCTAssertEqual(try current(opening.output)["id"] as? String, "important")
        let crossed = await queue.step(.init(), store: fixture.store)
        XCTAssertEqual(try current(crossed.output)["id"] as? String, "unread")
        let back = await queue.step(.init(direction: "back"), store: fixture.store)
        XCTAssertEqual(try current(back.output)["id"] as? String, "important")
        let forward = await queue.step(.init(), store: fixture.store)
        XCTAssertEqual(try current(forward.output)["id"] as? String, "unread")
        let backAgain = await queue.step(.init(direction: "back"), store: fixture.store)
        XCTAssertEqual(try current(backAgain.output)["id"] as? String, "important")
        _ = await queue.applyConfirmedEffects([
            GmailWriteEffect(
                account: account, scope: "thread", threadId: unread.threadId,
                messageIds: [unread.id], messageIdsComplete: true,
                operation: "modify", removeLabelIds: ["INBOX"]),
        ], store: fixture.store)
        let afterArchive = await queue.step(.init(), store: fixture.store)
        XCTAssertFalse(afterArchive.output.contains(#""id":"unread""#),
                       "a confirmed archive must not return from the saved newer stage")
        await queue.end()
    }

    func testSenderSweepDoesNotRestoreMailFromSavedNewerStage() async throws {
        let fixture = try StoreFixture()
        defer { fixture.close() }
        let previousScope = UserDefaults.standard.string(forKey: TriageScope.storageKey)
        // **Chosen explicitly**, so the saved `important → unread → all` plan matches whatever
        // the automatic start is.
        TriageScope.store(.important)
        defer {
            if let previousScope { UserDefaults.standard.set(previousScope, forKey: TriageScope.storageKey) }
            else { TriageScope.clear() }
        }
        // This week, so it is in the important scope; the unread row is older than the week.
        let important = row("important", thread: "important-thread",
                            date: Int64(Date().timeIntervalSince1970 * 1000), sender: "Priya")
        let unread = row("unread", thread: "unread-thread", date: 10, sender: "Sam <sam@example.test>")
        try await fixture.seed([important, unread], unread: ["important", "unread"])
        try await fixture.database.write { db in
            try MailStore.Label(user_id: "test-user", messageId: important.id, account: account,
                                label: "IMPORTANT").insert(db)
            try MailStore.SyncState(user_id: "test-user", account: account, historyId: "1",
                                    lastSyncedAt: Date(), backfillPageToken: nil, backfillDone: nil,
                                    inboxUnread: 2).insert(db)
        }
        try await saveSnapshot([item(important)], store: fixture.store, scope: "important",
                               scopePlan: ["important", "unread", "all"], band: "high")
        let queue = makeQueue()

        _ = await queue.step(.init(), store: fixture.store)
        let crossed = await queue.step(.init(), store: fixture.store)
        XCTAssertEqual(try current(crossed.output)["id"] as? String, "unread")
        let back = await queue.step(.init(direction: "back"), store: fixture.store)
        XCTAssertEqual(try current(back.output)["id"] as? String, "important")

        let removed = await queue.pruneAhead(senders: ["sam@example.test"], account: account)
        XCTAssertEqual(removed, 0,
                       "the matching mail is retained in the newer stage, not the active one")
        let afterSweep = await queue.step(.init(), store: fixture.store)
        XCTAssertFalse(afterSweep.output.contains(#""id":"unread""#),
                       "a successful inbox-wide sender sweep must reconcile saved stages")
        await queue.end()
    }

    /// "What's most important?" opens on a short list of the top few, in walk order, and
    /// only the first step carries it (issue #982).
    func testImportantWalkOpensWithTheRankedList() async throws {
        let fixture = try StoreFixture()
        defer { fixture.close() }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let rows = [row("newest", thread: "t1", date: now - 1_000, sender: "Dana"),
                    row("middle", thread: "t2", date: now - 2_000, sender: "Priya"),
                    row("oldest", thread: "t3", date: now - 3_000, sender: "Sam")]
        try await fixture.seed(rows, unread: ["newest"])
        // One high message and two unscored: a banded page stops at the end of a band, and
        // the list must still reach across into the next one.
        await fixture.store.applyBands(["newest": ("high", "needs a reply", 8)], account: account)
        let queue = makeQueue()

        let opening = await queue.step(.init(scope: .important), store: fixture.store)
        let ranked = try XCTUnwrap(try object(opening.output)["ranked"] as? [[String: Any]])
        XCTAssertEqual(ranked.compactMap { $0["subject"] as? String },
                       ["Subject newest", "Subject middle", "Subject oldest"],
                       "read mail from the week is in the list, in the order it will be walked")
        XCTAssertNotNil(try object(opening.output)["rankedIsForSaying"])
        XCTAssertEqual(try current(opening.output)["id"] as? String, "newest")

        let second = await queue.step(.init(), store: fixture.store)
        XCTAssertEqual(try current(second.output)["id"] as? String, "middle")
        XCTAssertNil(try object(second.output)["ranked"], "the list is said once")
        await queue.end()
    }

    /// An unread walk saved when the important pile was empty (a mailbox still caching at
    /// sign-in) yields to the week once it has mail, instead of holding the day.
    func testAStaleUnreadFallthroughYieldsToTheWeek() async throws {
        let fixture = try StoreFixture()
        defer { fixture.close() }
        TriageScope.clear()
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let rows = [row("promo", thread: "t1", date: now - 1_000, sender: "Shop"),
                    row("invite", thread: "t2", date: now - 2_000, sender: "Dana")]
        try await fixture.seed(rows, unread: ["promo"])
        await fixture.store.applyBands(["promo": ("low", "", 1), "invite": ("high", "wants a reply", 6)], account: account)
        try await saveSnapshot([item(rows[0])], store: fixture.store, scope: "unread",
                               scopePlan: ["important", "unread", "all"], band: "low")
        let queue = makeQueue()

        let opening = await queue.openingStep(store: fixture.store)
        XCTAssertEqual(try current(opening.output)["id"] as? String, "invite")
        XCTAssertNotNil(try object(opening.output)["ranked"], "the week opens with its list")
        await queue.end()
    }

    /// An important walk saved part-way through reopens from the top of the week at the next
    /// call, so high mail that arrived after it was saved leads, with the list.
    func testANewCallReopensOnTheWeekAfterTheWalkMovedOn() async throws {
        let fixture = try StoreFixture()
        defer { fixture.close() }
        TriageScope.clear()
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let rows = [row("arrived", thread: "t1", date: now - 1_000, sender: "Dana"),
                    row("first", thread: "t2", date: now - 2_000, sender: "Priya"),
                    row("second", thread: "t3", date: now - 3_000, sender: "Sam")]
        try await fixture.seed(rows, unread: [])
        await fixture.store.applyBands(["arrived": ("high", "needs the wire approved", 9),
                                        "first": ("normal", "", 5), "second": ("normal", "", 4)],
                                       account: account)
        try await saveSnapshot([item(rows[1]), item(rows[2])], store: fixture.store, scope: "important",
                               scopePlan: ["important", "unread", "all"], position: 2, band: "normal")
        let queue = makeQueue()

        let opening = await queue.openingStep(store: fixture.store)
        XCTAssertEqual(try current(opening.output)["id"] as? String, "arrived")
        XCTAssertNotNil(try object(opening.output)["ranked"], "the week opens with its list")
        await queue.end()
    }

    /// A week with nothing high says so, then walks its top first and bulk last.
    func testAWeekWithNothingHighSaysNothingIsImportant() async throws {
        let fixture = try StoreFixture()
        defer { fixture.close() }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let rows = [row("promo", thread: "t1", date: now - 1_000, sender: "Shop"),
                    row("summary", thread: "t2", date: now - 2_000, sender: "Classroom")]
        try await fixture.seed(rows, unread: ["promo"])
        await fixture.store.applyBands(["promo": ("low", "", 1), "summary": ("normal", "", 5)], account: account)
        let queue = makeQueue()

        let opening = await queue.step(.init(scope: .important), store: fixture.store)
        XCTAssertEqual(try object(opening.output)["interstitial"] as? String, "nothingImportant")
        XCTAssertNil(try object(opening.output)["ranked"])
        let first = await queue.step(.init(), store: fixture.store)
        XCTAssertEqual(try current(first.output)["id"] as? String, "summary")
        let second = await queue.step(.init(), store: fixture.store)
        XCTAssertEqual(try current(second.output)["id"] as? String, "promo", "bulk is walked, last")
        await queue.end()
    }

    /// A week of only bulk says so and asks about cleanup; yes walks it from the top.
    func testABulkOnlyWeekSaysNothingIsImportant() async throws {
        let fixture = try StoreFixture()
        defer { fixture.close() }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let rows = [row("promo", thread: "t1", date: now - 1_000, sender: "Shop"),
                    row("receipt", thread: "t2", date: now - 2_000, sender: "Store")]
        try await fixture.seed(rows, unread: ["promo", "receipt"])
        await fixture.store.applyBands(["promo": ("low", "", 2), "receipt": ("low", "", 1)], account: account)
        let queue = makeQueue()

        let opening = await queue.step(.init(scope: .important), store: fixture.store)
        let payload = try object(opening.output)
        XCTAssertEqual(payload["interstitial"] as? String, "nothingImportant")
        XCTAssertEqual(payload["script"] as? String, LocalTriageQueue.nothingImportantScript)
        XCTAssertNil(payload["item"])
        XCTAssertNil(payload["ranked"], "bulk is never called important")
        let first = await queue.step(.init(), store: fixture.store)
        XCTAssertEqual(try current(first.output)["id"] as? String, "promo", "yes serves the first, not the second")
        let second = await queue.step(.init(), store: fixture.store)
        XCTAssertEqual(try current(second.output)["id"] as? String, "receipt")
        await queue.end()
    }

    /// An account that has chosen no pile opens on the week ranked by importance, with the list
    /// (issue #982). It opened on unread after #823, when "important" was Gmail's stale marker.
    func testUnchosenAccountOpensOnTheRankedWeek() async throws {
        let fixture = try StoreFixture()
        defer { fixture.close() }
        TriageScope.clear()
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let rows = [row("newest", thread: "t1", date: now - 1_000, sender: "Dana"),
                    row("urgent", thread: "t2", date: now - 2_000, sender: "Priya"),
                    row("old", thread: "t3", date: 20, sender: "Sam")]
        try await fixture.seed(rows, unread: ["newest", "urgent", "old"])
        await fixture.store.applyBands(["urgent": ("high", "needs the contract signed", 9)], account: account)
        let queue = makeQueue()

        let opening = await queue.step(.init(), store: fixture.store)
        XCTAssertEqual(try current(opening.output)["id"] as? String, "urgent",
                       "the opening item is the week's most important, not the newest")
        let ranked = try XCTUnwrap(try object(opening.output)["ranked"] as? [[String: Any]])
        XCTAssertEqual(ranked.count, 2, "the list is the week; older unread waits for the next stage")
        await queue.end()
    }

    private struct StoreFixture {
        let directory: URL
        let database: DatabasePool
        var store: MailStore { MailStore(database: database, userId: "test-user") }

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            database = try DatabasePool(path: directory.appendingPathComponent("mail.sqlite").path)
            try database.write { db in
                try MailStore.createUserScopedSchema(db)
                try EmailCleanupRecord.createSchema(db)
                try DailyEmailQueueSnapshotRecord.createSchema(db)
                try DailyEmailQueueSnapshotRecord.addOwner(db)
            }
        }

        func seed(_ rows: [MailStore.Message], unread: Set<String>) async throws {
            try await database.write { db in
                for row in rows {
                    try row.insert(db)
                    try MailStore.Label(user_id: "test-user", messageId: row.id, account: row.account,
                                        label: "INBOX").insert(db)
                    if unread.contains(row.id) {
                        try MailStore.Label(user_id: "test-user", messageId: row.id, account: row.account,
                                            label: "UNREAD").insert(db)
                    }
                }
            }
        }

        func close() {
            do {
                try database.close()
                try FileManager.default.removeItem(at: directory)
            } catch { XCTFail("Could not remove test database: \(error)") }
        }
    }
}
