import XCTest
@testable import CodenameJo

@MainActor
final class DesktopFeedPreviewTests: XCTestCase {
    private let context = DesktopFeedPreview.Context(userID: "owner", profileID: "work",
        emails: ["work@example.test"], slackTeams: [])

    private func snapshot(_ id: String = "message", count: Int = 120) -> DesktopFeedPreview.Snapshot {
        .init(mail: .init(rows: [.init(id: id, source: "Email", title: id, detail: "Sender", reason: nil)], count: count),
              slack: .init())
    }

    func testOpeningRefreshCoalescesAndPollsOnlyAfterTwoMinutes() async throws {
        let loader = DeferredPreviewLoader()
        let service = DesktopFeedPreview(load: { await loader.load($0) })
        let now = Date(timeIntervalSince1970: 1_000)
        service.update(context: context, inSession: false, now: now)
        service.update(context: context, inSession: false, now: now)
        try await eventually { loader.requests.count == 1 }
        XCTAssertTrue(service.refreshing)
        XCTAssertNil(service.snapshot)
        loader.finish(0, with: snapshot())
        try await eventually { !service.refreshing }
        service.update(context: context, inSession: false, now: now.addingTimeInterval(119))
        XCTAssertEqual(loader.requests.count, 1)
        service.update(context: context, inSession: false, now: now.addingTimeInterval(120))
        try await eventually { loader.requests.count == 2 }
        XCTAssertEqual(service.snapshot?.mail.count, 120)
        loader.finish(1, with: snapshot(count: 121))
        try await eventually { service.snapshot?.mail.count == 121 }
    }

    func testManualRefreshBypassesPollingIntervalAndCoalescesClicksWithoutClearingRows() async throws {
        let loader = DeferredPreviewLoader()
        let service = DesktopFeedPreview(load: { await loader.load($0) })
        let now = Date()
        service.update(context: context, inSession: false, now: now)
        try await eventually { loader.requests.count == 1 }
        loader.finish(0, with: snapshot("original"))
        try await eventually { !service.refreshing }
        service.update(context: context, inSession: false, now: now, force: true)
        service.update(context: context, inSession: false, now: now, force: true)
        try await eventually { loader.requests.count == 2 }
        XCTAssertEqual(service.snapshot?.rows.first?.id, "original")
        XCTAssertTrue(loader.requests[1].forceRefresh)
        loader.finish(1, with: snapshot("new", count: 121))
        try await eventually { !service.refreshing }
        XCTAssertEqual(service.snapshot?.rows.first?.id, "new")
        XCTAssertEqual(loader.requests.count, 2)
    }

    func testProfileAndMembershipChangesDiscardLateResponses() async throws {
        let loader = DeferredPreviewLoader()
        let service = DesktopFeedPreview(load: { await loader.load($0) })
        service.update(context: context, inSession: false)
        try await eventually { loader.requests.count == 1 }
        let other = DesktopFeedPreview.Context(userID: "owner", profileID: "personal", emails: [], slackTeams: [])
        service.update(context: other, inSession: false)
        try await eventually { loader.requests.count == 2 }
        XCTAssertNil(service.snapshot)
        loader.finish(1, with: snapshot("personal"))
        try await eventually { service.snapshot?.rows.first?.id == "personal" }
        loader.finish(0, with: snapshot("old-work"))
        await Task.yield()
        XCTAssertEqual(service.snapshot?.rows.first?.id, "personal")
        let changed = DesktopFeedPreview.Context(userID: "owner", profileID: "personal",
            emails: ["new@example.test"], slackTeams: [])
        service.update(context: changed, inSession: false)
        XCTAssertEqual(service.snapshot?.rows.count, 0, "Membership changes remove unverified rows without a nil loading frame")
        try await eventually { loader.requests.count == 3 }
        service.update(context: nil, inSession: false)
        loader.finish(2, with: snapshot("signed-out"))
        await Task.yield()
        XCTAssertNil(service.snapshot)
        XCTAssertFalse(service.refreshing)
    }

    func testVoiceSessionCancelsPreviewAndEndingItRefreshesImmediately() async throws {
        let loader = DeferredPreviewLoader()
        let service = DesktopFeedPreview(load: { await loader.load($0) })
        service.update(context: context, inSession: true)
        XCTAssertFalse(service.refreshing)
        service.update(context: context, inSession: false)
        try await eventually { loader.requests.count == 1 }
        service.update(context: context, inSession: true)
        loader.finish(0, with: snapshot("late"))
        await Task.yield()
        XCTAssertNil(service.snapshot)
        service.update(context: context, inSession: false)
        try await eventually { loader.requests.count == 2 }
        loader.finish(1, with: snapshot("fresh"))
        try await eventually { service.snapshot?.rows.first?.id == "fresh" }
    }

    func testFailedRefreshKeepsLastPreviewButCannotClaimEmpty() async throws {
        let loader = DeferredPreviewLoader()
        let service = DesktopFeedPreview(load: { await loader.load($0) })
        let now = Date()
        service.update(context: context, inSession: false, now: now)
        try await eventually { loader.requests.count == 1 }
        loader.finish(0, with: snapshot())
        try await eventually { !service.refreshing }
        service.update(context: context, inSession: false, now: now.addingTimeInterval(120))
        try await eventually { loader.requests.count == 2 }
        loader.finish(1, with: .init(mail: .unavailable, slack: .init()))
        try await eventually { !service.refreshing }
        XCTAssertEqual(service.snapshot?.rows.first?.id, "message")
        XCTAssertTrue(service.snapshot?.incomplete == true)
        XCTAssertEqual(service.snapshot?.countLabel(filter: "Email"), "≈120")
        XCTAssertEqual(DesktopFeedPreview.Snapshot(mail: .unavailable, slack: .init()).countLabel(filter: "All"), "—")
        XCTAssertEqual(DesktopFeedPreview.Snapshot(mail: .init(), slack: .init()).countLabel(filter: "All"), "0")
    }

    func testIdleFilterCountsDoNotReplaceTheLiveQueueOrRenderedSelection() {
        let model = DesktopWorkspaceModel()
        model.sessionFeed = .init(rows: [.init(id: "live", source: "Email", title: "Live", detail: "Sender", reason: nil)])
        model.feedPreview = .init(mail: snapshot().mail,
            slack: .init(rows: [.init(id: "slack", source: "Slack", title: "Channel", detail: "Team", reason: nil)], count: 14))
        XCTAssertEqual(model.feedCountLabel, "≈134")
        XCTAssertEqual(model.filteredQueue.map(\.id), ["message", "slack"])
        XCTAssertEqual(model.renderedState.queueOrder, ["message", "slack"])
        XCTAssertEqual(model.sessionFeed.rows.map(\.id), ["live"])
        model.filter = "Slack"
        XCTAssertEqual(model.feedCountLabel, "≈14")
        XCTAssertEqual(model.filteredQueue.map(\.id), ["slack"])
        model.inSession = true
        model.filter = "All"
        XCTAssertEqual(model.filteredQueue.map(\.id), ["live"])
        XCTAssertEqual(model.feedCountLabel, "1")
        XCTAssertFalse(model.micLive)
        XCTAssertEqual(model.state, .disconnected)
    }

    func testMembershipHydrationRetainsAuthorizedRowsAndRejectsOldGeneration() async throws {
        let loader = DeferredPreviewLoader()
        let service = DesktopFeedPreview(load: { await loader.load($0) })
        let a = DesktopFeedRow.email(account: "work@example.test", messageID: "A", subject: "Original", sender: "Sender")
        service.update(context: context, inSession: false)
        try await eventually { loader.requests.count == 1 }
        loader.finish(0, with: .visible([a]))
        try await eventually { !service.refreshing }
        service.update(context: nil, inSession: false, hydratingOwner: "owner")
        XCTAssertEqual(service.snapshot?.rows, [a])
        var expanded = context
        expanded = .init(userID: context.userID, profileID: context.profileID,
                         emails: context.emails + ["second@example.test"], slackTeams: [])
        service.update(context: expanded, inSession: false)
        try await eventually { loader.requests.count == 2 }
        XCTAssertEqual(service.snapshot?.rows, [a])
        service.update(context: context, inSession: false)
        try await eventually { loader.requests.count == 3 }
        loader.finish(2, with: .visible([a]))
        try await eventually { !service.refreshing }
        loader.finish(1, with: snapshot("obsolete"))
        await Task.yield()
        XCTAssertEqual(service.snapshot?.rows, [a])
        service.update(context: nil, inSession: false, hydratingOwner: "owner", hydratingProfile: "personal")
        XCTAssertNil(service.snapshot, "A new profile clears immediately, even before its accounts finish loading")
        service.update(context: nil, inSession: false)
        XCTAssertNil(service.snapshot, "Sign-out clears even during hydration")
    }

    func testArchiveDuringRefreshCannotReturnFromDelayedResultOrPartialFailure() async throws {
        let loader = DeferredPreviewLoader()
        let service = DesktopFeedPreview(load: { await loader.load($0) })
        let rows = ["A", "B"].map { DesktopFeedRow.email(account: "work@example.test", messageID: $0, subject: $0, sender: "Sender") }
        service.update(context: context, inSession: false)
        try await eventually { loader.requests.count == 1 }
        loader.finish(0, with: .visible(rows))
        try await eventually { !service.refreshing }
        service.update(context: context, inSession: false, force: true)
        try await eventually { loader.requests.count == 2 }
        service.remove(rows[0].selection!)
        loader.finish(1, with: .visible(rows))
        try await eventually { !service.refreshing }
        XCTAssertEqual(service.snapshot?.rows, [rows[1]])
        XCTAssertEqual(service.snapshot?.mail.count, 1)
        service.update(context: context, inSession: false, force: true)
        try await eventually { loader.requests.count == 3 }
        service.remove(rows[1].selection!)
        loader.finish(2, with: .init(mail: .unavailable, slack: .init()))
        try await eventually { !service.refreshing }
        XCTAssertEqual(service.snapshot?.rows, [])
        XCTAssertEqual(service.snapshot?.mail.count, 0)
        XCTAssertEqual(service.snapshot?.countLabel(filter: "All"), "—")
    }

    func testPartialSourceKeepsMissingRowsButSuccessfulRefreshCanRemoveThem() {
        let a = DesktopFeedRow.email(account: "work@example.test", messageID: "A", subject: "Original", sender: "Sender")
        let b = DesktopFeedRow.email(account: "second@example.test", messageID: "B", subject: "Other inbox", sender: "Sender")
        let updated = DesktopFeedRow.email(account: "work@example.test", messageID: "A", subject: "Updated", sender: "Sender")
        let previous = DesktopFeedPreview.Snapshot.visible([a, b])
        let partial = DesktopFeedPreview.Snapshot(mail: .init(rows: [updated], count: 1, incomplete: true), slack: .unavailable)
        let retained = partial.retainingUnavailable(from: previous)
        XCTAssertEqual(retained.rows, [updated, b])
        XCTAssertEqual(retained.rows.map(\.id), previous.rows.map(\.id))
        XCTAssertEqual(DesktopFeedPreview.Snapshot.visible([updated]).retainingUnavailable(from: retained).rows, [updated])
        XCTAssertEqual(retained.restricted(to: context).rows, [updated])
        let oneInboxUnavailable = DesktopFeedPreview.Snapshot(mail: .init(rows: [], count: 0, incomplete: true,
            unavailableAccounts: ["second@example.test"]), slack: .init())
        XCTAssertEqual(oneInboxUnavailable.retainingUnavailable(from: previous).rows, [b],
            "A failed second inbox must not resurrect messages confirmed absent from the first inbox")
    }

    func testIdleSelectionChangesOnlyAfterConfirmedRemovalFromItsSource() {
        let model = DesktopWorkspaceModel()
        let rows = ["A", "B"].map { DesktopFeedRow.email(account: "work@example.test", messageID: $0, subject: $0, sender: "Sender") }
        model.feedPreview = .visible(rows); model.previewSelection = rows[0]
        model.applyPreview(.init(mail: .init(rows: [rows[1]], count: nil, incomplete: true), slack: .init()))
        XCTAssertEqual(model.previewSelection, rows[0], "Failure is not confirmation that the selected source disappeared")
        model.applyPreview(.visible(rows))
        model.applyPreview(.visible([rows[1]]))
        XCTAssertEqual(model.previewSelection, rows[1])
        XCTAssertEqual(model.feedRows, [rows[1]])
    }

    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Preview did not reach the expected state")
    }
}

@MainActor
private final class DeferredPreviewLoader {
    var requests: [DesktopFeedPreview.Context] = []
    var pending: [Int: CheckedContinuation<DesktopFeedPreview.Snapshot, Never>] = [:]
    func load(_ context: DesktopFeedPreview.Context) async -> DesktopFeedPreview.Snapshot {
        let index = requests.count
        requests.append(context)
        return await withCheckedContinuation { pending[index] = $0 }
    }
    func finish(_ index: Int, with snapshot: DesktopFeedPreview.Snapshot) {
        pending.removeValue(forKey: index)?.resume(returning: snapshot)
    }
}
