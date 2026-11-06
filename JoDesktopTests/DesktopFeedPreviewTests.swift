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
        XCTAssertNil(service.snapshot)
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
