import XCTest
@testable import CodenameJo

@MainActor
final class FeedItemSelectionTests: XCTestCase {
    private let account = "selection@example.test"
    private let store = MailStore(database: nil, userId: "fixture-selection")

    private func open() async -> LocalTriageQueue {
        let queue = LocalTriageQueue(mailAccounts: { ["selection@example.test"] })
        let rows = (1...4).map { index in
            MailStore.Message(user_id: "fixture-selection", id: "m\(index)", account: account,
                threadId: "t\(index)", sender: "Sender \(index)", recipient: account,
                subject: "Email \(index)", snippet: "Synthetic content", internalDate: Int64(100 - index), cachedAt: Date())
        }
        await queue.adopt(rows, store: store)
        _ = await queue.step(.init(account: account), store: store, dealtWith: false)
        return queue
    }

    func testSelectionPinsItemChangesActionTargetAndResumesUnfinishedCursor() async throws {
        let old = ProfileRuntime.snapshot
        ProfileRuntime.install(nil)
        defer { ProfileRuntime.install(old) }
        let queue = await open()
        let first = await queue.desktopSnapshot()
        let selected = MailSelection(account: account, messageID: "m3")
        let selectionOutput = await queue.selectPreparedEmail(selected, profileID: nil)
        let output = try XCTUnwrap(selectionOutput)
        let snapshot = await queue.desktopSnapshot()
        XCTAssertEqual(snapshot.currentID, "m3")
        XCTAssertEqual(snapshot.items.map(\.id), ["m3", "m1", "m2", "m4"])
        let isSelected = await queue.standingOn(messageId: "m3", account: account)
        let oldSelected = await queue.standingOn(messageId: "m1", account: account)
        XCTAssertTrue(isSelected)
        XCTAssertFalse(oldSelected)
        var focus = FeedFocusTracker()
        guard case .email(let email) = focus.applyTriage(output: output) else { return XCTFail("Expected selected email") }
        XCTAssertEqual(email.messageId, "m3")
        XCTAssertNil(email.displayedPosition)
        XCTAssertTrue(snapshot.revision > first.revision)
        let finished = await queue.dealtWith
        XCTAssertTrue(finished.isEmpty, "Selecting must not finish any mail")
        _ = await queue.step(.init(), store: store, dealtWith: false)
        let resumed = await queue.desktopSnapshot()
        XCTAssertEqual(resumed.currentID, "m1")
        XCTAssertEqual(resumed.items.map(\.id), ["m1", "m2", "m4"])
    }

    func testSwitchingSelectionDoesNotConsumeThePreviouslySelectedItem() async throws {
        let old = ProfileRuntime.snapshot
        ProfileRuntime.install(nil)
        defer { ProfileRuntime.install(old) }
        let queue = await open()
        _ = await queue.selectPreparedEmail(.init(account: account, messageID: "m3"), profileID: nil)
        _ = await queue.selectPreparedEmail(.init(account: account, messageID: "m4"), profileID: nil)
        let snapshot = await queue.desktopSnapshot()
        XCTAssertEqual(snapshot.items.map(\.id), ["m4", "m1", "m2", "m3"])
        let rejectedAccount = await queue.selectPreparedEmail(.init(account: "other@example.test", messageID: "m1"), profileID: nil)
        let rejectedProfile = await queue.selectPreparedEmail(.init(account: account, messageID: "m1"), profileID: "old-profile")
        XCTAssertNil(rejectedAccount)
        XCTAssertNil(rejectedProfile)
        let current = await queue.currentId
        XCTAssertEqual(current, "m4")
    }

    func testIdlePreviewPinsSelectionAndEnablesActionsForThatExactSource() {
        let model = DesktopWorkspaceModel()
        let rows = (1...3).map { DesktopFeedRow.email(account: account, messageID: "m\($0)", subject: "Message \($0)", sender: "Sender") }
        model.feedPreview = .init(mail: .init(rows: rows), slack: .init())
        model.previewSelection = rows[2]
        XCTAssertEqual(model.feedRows.map(\.id), [rows[2].id, rows[0].id, rows[1].id])
        XCTAssertTrue(model.isCurrentRow(rows[2]))
        XCTAssertEqual(model.readerRequest(ownerID: "fixture", headersOnly: false)?.selection, rows[2].selection)
        XCTAssertEqual(model.feedActionContext?.selection, rows[2].selection)
        model.profileID = "another-profile"
        XCTAssertNil(model.previewSelection)
    }

    func testActivityFocusDisarmsHiddenEmailAndReturningRestoresItsPlace() throws {
        let model = DesktopWorkspaceModel()
        let row = DesktopFeedRow.email(account: account, messageID: "held", subject: "Held email", sender: "Sender")
        model.feedPreview = .init(mail: .init(rows: [row]), slack: .init())
        model.previewSelection = row
        let job = try JSONDecoder().decode(DispatchJob.self, from: Data(#"{"id":"00000000-0000-0000-0000-000000000001","task":"Research","state":"done","result":"Recorded result"}"#.utf8))
        XCTAssertNotNil(model.feedActionContext)
        model.selectedJob = job
        XCTAssertNil(model.feedActionContext)
        XCTAssertNil(model.renderedState.focus)
        XCTAssertEqual(model.renderedState.displayBranch, "activity")
        XCTAssertEqual(model.renderedState.activityID, job.id)
        XCTAssertFalse(model.isCurrentRow(row))
        XCTAssertEqual(model.feedRows, [row])
        model.selectedJob = nil
        XCTAssertEqual(model.feedActionContext?.selection, row.selection)
        XCTAssertTrue(model.isCurrentRow(row))
        model.selectedJob = job
        model.profileID = "other"
        XCTAssertNil(model.selectedJob)
    }

    func testManualRefreshAddsPreparedWorkWithoutMovingCurrentOrRestoringHandledItems() async throws {
        let old = ProfileRuntime.snapshot
        ProfileRuntime.install(nil)
        defer { ProfileRuntime.install(old) }
        let source = RefreshSectionSource()
        let queue = LocalTriageQueue(mailAccounts: { ["selection@example.test", "second@example.test"] },
            feedSectionLoader: { await source.load($0) }, unreadOpeningLoader: { _ in nil })
        await queue.configure(coachingPlan: nil, forceOnboardingFeedLesson: false, sequentialFeed: true,
            calendarFeedDue: false, localCalendar: false,
            feedSections: ["selection@example.test", "second@example.test"].map { .init(kind: .remaining, account: $0) })
        _ = await queue.openingStep(store: store)
        await queue.awaitFeedSectionPreparation()
        _ = await queue.step(.init(), store: store, dealtWith: true)
        let before = await queue.desktopSnapshot()
        await source.setCount(4)
        let error = await queue.refreshDesktopFeed(store: store)
        XCTAssertNil(error)
        let after = await queue.desktopSnapshot()
        XCTAssertEqual(after.currentID, before.currentID)
        XCTAssertEqual(after.account, before.account)
        let rows = DesktopSessionFeed(mail: after).rows
        XCTAssertTrue(rows.contains { $0.selection == .init(account: account, messageID: "m4") })
        XCTAssertTrue(rows.contains { $0.selection == .init(account: "second@example.test", messageID: "m4") })
        XCTAssertFalse(rows.contains { $0.selection == .init(account: account, messageID: "m1") })
        await source.setCount(nil)
        let failed = await queue.refreshDesktopFeed(store: store)
        XCTAssertNotNil(failed)
        let retained = await queue.desktopSnapshot()
        XCTAssertEqual(DesktopSessionFeed(mail: retained).rows, rows)
    }

    func testRefreshCoalescesAndDiscardsALateResponseAfterProfileSwitch() async throws {
        let old = ProfileRuntime.snapshot
        ProfileRuntime.install(nil)
        defer { ProfileRuntime.install(old) }
        let source = RefreshSectionSource()
        let queue = LocalTriageQueue(mailAccounts: { ["selection@example.test"] },
            feedSectionLoader: { await source.load($0) }, unreadOpeningLoader: { _ in nil })
        await queue.configure(coachingPlan: nil, forceOnboardingFeedLesson: false, sequentialFeed: true,
            calendarFeedDue: false, localCalendar: false,
            feedSections: [.init(kind: .remaining, account: account)])
        _ = await queue.openingStep(store: store)
        let before = await queue.desktopSnapshot()
        await source.setCount(4)
        await source.pauseNextLoad()
        let refresh = Task { await queue.refreshDesktopFeed(store: store) }
        for _ in 0..<100 {
            if await source.isPaused { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let paused = await source.isPaused
        XCTAssertTrue(paused)
        let calls = await source.calls
        _ = await queue.refreshDesktopFeed(store: store)
        let afterSecondClick = await source.calls
        XCTAssertEqual(afterSecondClick, calls)
        ProfileRuntime.install(.init(profileId: "other", isDefault: false, emails: ["other@example.test"]))
        await source.resume()
        let error = await refresh.value
        XCTAssertNotNil(error)
        ProfileRuntime.install(nil)
        let after = await queue.desktopSnapshot()
        XCTAssertEqual(after.items, before.items)
        XCTAssertEqual(after.currentID, before.currentID)
    }

    func testSelectionAcrossPreparedSectionsKeepsTheOriginalAccountAndQueue() async throws {
        let old = ProfileRuntime.snapshot
        ProfileRuntime.install(nil)
        defer { ProfileRuntime.install(old) }
        let accounts = ["first@example.test", "second@example.test"]
        let queue = LocalTriageQueue(mailAccounts: { accounts }, feedSectionLoader: { section in
            (1...6).map { index in
                .init(account: section.account!, id: "m\(index)", threadId: "t\(index)", from: "Sender",
                    subject: "Message \(index)", date: "", snippet: "Synthetic", internalDate: Int64(100 - index), acted: nil)
            }
        }, unreadOpeningLoader: { _ in nil })
        await queue.configure(coachingPlan: nil, forceOnboardingFeedLesson: false, sequentialFeed: true,
            calendarFeedDue: false, localCalendar: false,
            feedSections: accounts.map { .init(kind: .remaining, account: $0) })
        _ = await queue.openingStep(store: store)
        await queue.awaitFeedSectionPreparation()
        let selected = MailSelection(account: accounts[1], messageID: "m3")
        let output = await queue.selectPreparedEmail(selected, profileID: nil)
        XCTAssertNotNil(output)
        let selectedFeed = DesktopSessionFeed(mail: await queue.desktopSnapshot())
        XCTAssertEqual(selectedFeed.current, selected)
        XCTAssertEqual(selectedFeed.rows.first?.selection, selected)
        XCTAssertEqual(selectedFeed.rows.filter { $0.selection == selected }.count, 1)
        _ = await queue.step(.init(), store: store, dealtWith: false)
        let resumed = DesktopSessionFeed(mail: await queue.desktopSnapshot())
        XCTAssertEqual(resumed.current, .init(account: accounts[0], messageID: "m1"))
        XCTAssertFalse(resumed.rows.contains { $0.selection == selected })
        XCTAssertTrue(resumed.rows.contains { $0.selection == .init(account: accounts[0], messageID: "m3") })
    }
}

private actor RefreshSectionSource {
    var count: Int? = 2
    var calls = 0
    private var pause = false
    private var continuation: CheckedContinuation<Void, Never>?
    var isPaused: Bool { continuation != nil }
    func pauseNextLoad() { pause = true }
    func resume() { continuation?.resume(); continuation = nil }
    func setCount(_ value: Int?) { count = value }
    func load(_ section: FeedSection) async -> [LocalTriageQueue.Item]? {
        calls += 1
        if pause { pause = false; await withCheckedContinuation { continuation = $0 } }
        guard let count else { return nil }
        return (1...count).map { index in
            .init(account: section.account!, id: "m\(index)", threadId: "t\(index)", from: "Sender",
                  subject: "Message \(index)", date: "", snippet: "Synthetic", internalDate: Int64(100 - index), acted: nil)
        }
    }
}
