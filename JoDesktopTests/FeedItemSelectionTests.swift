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

    func testIdlePreviewPinsSelectionAndRequestsReaderWithoutEnablingActions() {
        let model = DesktopWorkspaceModel()
        let rows = (1...3).map { DesktopFeedRow.email(account: account, messageID: "m\($0)", subject: "Message \($0)", sender: "Sender") }
        model.feedPreview = .init(mail: .init(rows: rows), slack: .init())
        model.previewSelection = rows[2]
        XCTAssertEqual(model.feedRows.map(\.id), [rows[2].id, rows[0].id, rows[1].id])
        XCTAssertTrue(model.isCurrentRow(rows[2]))
        XCTAssertEqual(model.readerRequest(ownerID: "fixture", headersOnly: false)?.selection, rows[2].selection)
        XCTAssertNil(model.feedActionContext)
        model.profileID = "another-profile"
        XCTAssertNil(model.previewSelection)
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
