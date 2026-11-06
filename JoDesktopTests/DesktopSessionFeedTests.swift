import Combine
import GRDB
import XCTest
@testable import CodenameJo

@MainActor
final class DesktopSessionFeedTests: XCTestCase {
    func testPreviewAndSessionRowsKeepTheSameAccountScopedIdentity() {
        let first = mail(account: "work@example.test")
        let second = mail(account: "personal@example.test")
        let slack = SlackQueueSnapshot.Item(teamId: "T1", teamName: "Work", channelId: "C1",
            withUserId: nil, label: "General", kind: "channel", unread: 2, more: false, messages: [], why: "")
        let session = DesktopSessionFeed(mail: .init(items: [first, second], currentID: first.id,
            account: first.account, scope: "unread", status: .ready), slack: [slack])
        let preview = DesktopFeedPreview.Snapshot(mail: .init(rows: [first, second].map {
            .email(account: $0.account, messageID: $0.id, subject: $0.subject, sender: $0.from)
        }), slack: .init(rows: [.slack(slack)]))

        XCTAssertEqual(session.rows.map(\.id), preview.rows.map(\.id))
        XCTAssertEqual(Set(session.rows.map(\.id)).count, 3)
        XCTAssertEqual(session.rows[0].title, "No subject")
        XCTAssertEqual(session.rows[0].selection, session.current)
        XCTAssertNotEqual(session.rows[1].selection, session.current)
        XCTAssertEqual(session.rows[0].reason, "Needs a reply")
        XCTAssertNil(session.rows[2].selection)
        XCTAssertNil(session.rows[2].reason)
    }

    func testQueueProjectionPublishesOneCoherentUpdateAndThenCompletes() {
        let item = mail(account: "work@example.test")
        let snapshot = LocalTriageQueue.DesktopSnapshot(items: [item], currentID: item.id,
            account: item.account, scope: "unread", status: .ready, revision: 7)
        let model = DesktopWorkspaceModel()
        model.inSession = true
        model.focus = .email(.init(sender: item.from, subject: item.subject, snippet: "",
            account: item.account, position: 1, total: 1, messageId: item.id))
        XCTAssertTrue(model.selectionIsTransitioning)
        var updates: [DesktopSessionFeed] = []
        let subscription = model.$sessionFeed.dropFirst().sink { updates.append($0) }
        defer { subscription.cancel() }

        model.sessionFeed = .init(mail: snapshot)

        XCTAssertEqual(updates.count, 1)
        XCTAssertEqual(updates.first?.current?.messageID, item.id)
        XCTAssertEqual(updates.first?.rows.count, 1)
        XCTAssertEqual(updates.first?.status, .ready)
        XCTAssertEqual(updates.first?.revision, 7)
        XCTAssertFalse(model.selectionIsTransitioning)
        XCTAssertEqual(model.renderedState.queueRevision, 7)
        XCTAssertEqual(model.renderedState.queueScope, "unread")
        XCTAssertEqual(model.renderedState.focus, model.renderedState.queueCurrent)
        XCTAssertEqual(model.feedCountLabel, "1")

        model.sessionFeed = .init(status: .complete)
        XCTAssertFalse(model.feedComplete, "The spoken focus must also acknowledge completion")
        model.focus = .complete(.init())
        XCTAssertTrue(model.feedComplete)
        XCTAssertNil(model.renderedState.queueCurrent)
        XCTAssertTrue(model.renderedState.queueOrder.isEmpty)
    }

    func testMissingAccountDoesNotInventAnActionableSelection() {
        let item = mail(account: "work@example.test")
        let snapshot = DesktopSessionFeed(mail: .init(items: [item], currentID: item.id,
            account: nil, scope: "unread", status: .unavailable))
        XCTAssertNil(snapshot.current)
        XCTAssertEqual(snapshot.rows.count, 1)
        XCTAssertEqual(snapshot.status, .unavailable)
    }

    private func mail(account: String) -> LocalTriageQueue.Item {
        .init(account: account, id: "same-id", threadId: "thread", from: "Sender", subject: "",
              date: "", snippet: "", internalDate: 0, acted: nil, importanceWhy: "Needs a reply")
    }
}


@MainActor
final class FeedSectionTests: XCTestCase {
    func testSectionPreferencesKeepTogglesOrderAndUserProfileIsolation() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let context = LocalContextStore(url: folder)
        defer { try? context.dbPool?.close(); try? FileManager.default.removeItem(at: folder) }
        let rows = WorkspaceProfileRows(dbPool: context.dbPool)
        let first = try await rows.list(userId: "first")[0]
        let other = try await rows.list(userId: "other")[0]
        try await rows.adopt(userId: "first", emails: ["a@test.invalid", "b@test.invalid"], into: first.id)
        var sections = try await rows.feedSections(userId: "first", profileId: first.id)
        XCTAssertEqual(sections.map(\.kind), [.important, .remaining, .important, .remaining, .calendar, .slack])
        let calendar = sections.remove(at: 4)
        sections.insert(calendar, at: 0)
        sections[1].enabled = false
        try await rows.saveFeedSections(sections, userId: "first", profileId: first.id)
        let restored = try await rows.feedSections(userId: "first", profileId: first.id)
        XCTAssertEqual(restored, sections)
        let unrelated = try await rows.feedSections(userId: "other", profileId: other.id)
        XCTAssertEqual(unrelated.map(\.kind), [.calendar, .slack])
        try await rows.forget(userId: "first", email: "a@test.invalid")
        try await rows.adopt(userId: "first", emails: ["c@test.invalid"], into: first.id)
        let updated = try await rows.feedSections(userId: "first", profileId: first.id)
        XCTAssertEqual(updated.first?.kind, .calendar)
        XCTAssertFalse(updated.contains { $0.account == "a@test.invalid" })
        XCTAssertEqual(updated.suffix(2).map(\.account), ["c@test.invalid", "c@test.invalid"])
    }

    func testSmallInboxPreparesOtherInboxAndCrossesWithoutAnOffer() async throws {
        ProfileRuntime.install(nil)
        let source = SectionSource()
        let queue = LocalTriageQueue(mailAccounts: { ["a@test.invalid", "b@test.invalid"] },
            feedSectionLoader: { await source.load($0) }, unreadOpeningLoader: { _ in nil })
        let sections = [FeedSection(kind: .remaining, account: "a@test.invalid"),
                        FeedSection(kind: .remaining, account: "b@test.invalid")]
        let store = MailStore(database: nil, userId: "fixture")
        await configure(queue, sections: sections)
        _ = await queue.openingStep(store: store)
        await queue.awaitFeedSectionPreparation()
        let before = await queue.desktopSnapshot()
        XCTAssertEqual(before.currentID, "a@test.invalid-0")
        XCTAssertEqual(before.sections?.map(\.section.id), sections.map(\.id))
        XCTAssertEqual(before.sections?.flatMap(\.rows).count, 26)
        for _ in 0..<6 { _ = await queue.step(.init(), store: store, dealtWith: false) }
        let after = await queue.desktopSnapshot()
        XCTAssertEqual(after.currentID, "b@test.invalid-0")
        XCTAssertEqual(after.status, .ready)
        let calls = await source.calls
        XCTAssertEqual(calls.filter { $0 == sections[1].id }.count, 1)
        await queue.end()
    }

    func testDisabledSectionsDoNotLoadAndReorderingKeepsCurrentSelection() async throws {
        let source = SectionSource()
        let first = FeedSection(kind: .remaining, account: "a@test.invalid")
        let second = FeedSection(kind: .remaining, account: "b@test.invalid")
        let disabled = FeedSection(kind: .important, account: "a@test.invalid", enabled: false)
        ProfileRuntime.install(.init(profileId: "test", isDefault: false,
            emails: ["a@test.invalid", "b@test.invalid"], feedSections: [first, second, disabled]))
        defer { ProfileRuntime.install(nil) }
        let queue = LocalTriageQueue(mailAccounts: { ["a@test.invalid", "b@test.invalid"] },
            feedSectionLoader: { await source.load($0) }, unreadOpeningLoader: { _ in nil })
        let store = MailStore(database: nil, userId: "fixture")
        await configure(queue, sections: [first, second, disabled])
        _ = await queue.openingStep(store: store)
        await queue.awaitFeedSectionPreparation()
        let calls = await source.calls
        XCTAssertFalse(calls.contains(disabled.id))
        var turnedOff = second; turnedOff.enabled = false
        ProfileRuntime.install(.init(profileId: "test", isDefault: false,
            emails: ["a@test.invalid", "b@test.invalid"], feedSections: [turnedOff, first, disabled]))
        let output = await queue.step(.init(), store: store, dealtWith: false).output
        XCTAssertTrue(output.contains("a@test.invalid-1"))
        let snapshot = await queue.desktopSnapshot()
        XCTAssertEqual(snapshot.sections?.map(\.section.id), [first.id])
        await queue.end()
    }

    func testUnavailableSectionStaysUnfinishedAndRetries() async throws {
        ProfileRuntime.install(nil)
        let source = SectionSource(failFirst: true)
        let section = FeedSection(kind: .remaining, account: "a@test.invalid")
        let queue = LocalTriageQueue(mailAccounts: { ["a@test.invalid"] },
            feedSectionLoader: { await source.load($0) }, unreadOpeningLoader: { _ in nil })
        let store = MailStore(database: nil, userId: "fixture")
        await configure(queue, sections: [section])
        _ = await queue.openingStep(store: store)
        let failed = await queue.desktopSnapshot()
        XCTAssertEqual(failed.status, .unavailable)
        _ = await queue.step(.init(), store: store, dealtWith: false)
        let recovered = await queue.desktopSnapshot()
        XCTAssertEqual(recovered.currentID, "a@test.invalid-0")
        XCTAssertEqual(recovered.status, .ready)
        await queue.end()
    }

    func testImportantAndOtherMailAreDisjointIncludingUnrankedAndOlderMail() {
        let now = Date()
        let recent = Int64(now.timeIntervalSince1970 * 1000)
        XCTAssertTrue(FeedSection.isImportant(band: "high", received: recent, now: now))
        XCTAssertFalse(FeedSection.isImportant(band: nil, received: recent, now: now))
        XCTAssertFalse(FeedSection.isImportant(band: "medium", received: recent, now: now))
        XCTAssertFalse(FeedSection.isImportant(band: "high", received: recent - 8 * 86400 * 1000, now: now))
    }

    func testCalendarCanPrecedeMailAndStopWhileCalendarIsCurrent() async throws {
        defer { ProfileRuntime.install(nil) }
        let source = SectionSource()
        let queue = LocalTriageQueue(mailAccounts: { ["a@test.invalid"] },
            feedSectionLoader: { await source.load($0) }, unreadOpeningLoader: { _ in nil })
        let sections = [FeedSection(kind: .calendar), FeedSection(kind: .remaining, account: "a@test.invalid")]
        let profile = WorkspaceProfile(id: "calendar-first", name: "Test", isDefault: true, createdAt: "")
        ProfileRuntime.install(.init(profileId: profile.id, isDefault: true, emails: ["a@test.invalid"], feedSections: sections))
        let store = MailStore(database: nil, userId: "fixture")
        await configure(queue, sections: sections)
        await queue.installCalendarPrefetch(.init(events: [], attendees: [], covered: true,
            servedLive: false, successful: true, ms: 0))
        await queue.configureProfileHandoff(current: profile, profiles: [profile], enabled: true, newCall: true)
        let calendar = await queue.openingStep(store: store).output
        XCTAssertTrue(calendar.contains("\"configuredSection\":\"calendar\""))
        XCTAssertTrue(calendar.contains("calendarEvents"))
        await queue.awaitFeedSectionPreparation()
        let prepared = await queue.desktopSnapshot()
        XCTAssertNil(prepared.currentID)
        XCTAssertEqual(prepared.sections?.flatMap(\.rows).count, 6)
        let mail = await queue.step(.init(), store: store, dealtWith: false).output
        XCTAssertTrue(mail.contains("a@test.invalid-0"))
        await configure(queue, sections: sections)
        _ = await queue.openingStep(store: store)
        let stopped = await queue.step(.init(stop: true), store: store).output
        XCTAssertTrue(stopped.contains("stopped"))
        XCTAssertFalse(stopped.contains("No queue was running"))
        await queue.end()
    }

    func testAllDisabledFinishesWithoutLoadingOrClaimingInboxEmpty() async throws {
        ProfileRuntime.install(nil)
        let source = SectionSource()
        let queue = LocalTriageQueue(mailAccounts: { ["a@test.invalid"] },
            feedSectionLoader: { await source.load($0) }, unreadOpeningLoader: { _ in nil })
        let store = MailStore(database: nil, userId: "fixture")
        let sections = FeedSection.resolved([], accounts: ["a@test.invalid"]).map { section in
            var disabled = section; disabled.enabled = false; return disabled
        }
        await configure(queue, sections: sections)
        let output = await queue.openingStep(store: store).output
        XCTAssertTrue(output.contains("\"configuredSection\":\"complete\""))
        XCTAssertTrue(output.contains("disabled sections were not walked"))
        let calls = await source.calls
        XCTAssertTrue(calls.isEmpty)
        let snapshot = await queue.desktopSnapshot()
        XCTAssertEqual(snapshot.status, .complete)
        await queue.end()
    }

    func testResumeKeepsTheCurrentEmailAndProfileProgressIsPrivate() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let context = LocalContextStore(url: folder)
        defer { ProfileRuntime.install(nil); try? context.dbPool?.close(); try? FileManager.default.removeItem(at: folder) }
        let rows = WorkspaceProfileRows(dbPool: context.dbPool)
        let profile = try await rows.list(userId: "fixture")[0]
        let section = FeedSection(kind: .remaining, account: "a@test.invalid")
        ProfileRuntime.install(.init(profileId: profile.id, isDefault: true, emails: ["a@test.invalid"], feedSections: [section]))
        let source = SectionSource()
        let queue = LocalTriageQueue(profileRows: rows, mailAccounts: { ["a@test.invalid"] }, feedSectionLoader: { await source.load($0) }, unreadOpeningLoader: { _ in nil })
        let store = MailStore(database: context.dbPool, userId: "fixture")
        await configure(queue, sections: [section])
        _ = await queue.openingStep(store: store)
        _ = await queue.step(.init(), store: store, dealtWith: false)
        await queue.pauseForConversationEnd(store: store)
        await configure(queue, sections: [section])
        _ = await queue.openingStep(store: store)
        let resumed = await queue.desktopSnapshot()
        XCTAssertEqual(resumed.currentID, "a@test.invalid-1")
        let privateProgress = try await rows.feedProgress(userId: "someone-else", profileId: profile.id)
        XCTAssertNil(privateProgress)
        await queue.end()
    }

    func testDatabaseRankingPartitionsSameIDsAcrossAccountsAndKeepsAnsweredMailInOther() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let context = LocalContextStore(url: folder)
        defer { try? context.dbPool?.close(); try? FileManager.default.removeItem(at: folder) }
        let db = try XCTUnwrap(context.dbPool)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try await db.write { db in
            for (account, band) in [("a@test.invalid", "high"), ("b@test.invalid", "low")] {
                try MailStore.Message(user_id: "u", id: "same", account: account, threadId: "t", sender: "sender@else.invalid",
                    recipient: account, subject: "Test", snippet: "", internalDate: now, cachedAt: Date(), importanceBand: band).insert(db)
                try MailStore.Label(user_id: "u", messageId: "same", account: account, label: "INBOX").insert(db)
            }
        }
        let store = MailStore(database: db, userId: "u")
        let importantA = await store.importantFeedIDs(among: ["same"], account: "a@test.invalid")
        let importantB = await store.importantFeedIDs(among: ["same"], account: "b@test.invalid")
        XCTAssertEqual(importantA, ["same"])
        XCTAssertEqual(importantB, [])
        try await db.write { db in
            try MailStore.Message(user_id: "u", id: "reply", account: "a@test.invalid", threadId: "t", sender: "a@test.invalid",
                recipient: "sender@else.invalid", subject: "Re", snippet: "", internalDate: now + 1, cachedAt: Date()).insert(db)
            try MailStore.Label(user_id: "u", messageId: "reply", account: "a@test.invalid", label: "SENT").insert(db)
        }
        let answered = await store.importantFeedIDs(among: ["same"], account: "a@test.invalid")
        XCTAssertEqual(answered, [])
    }

    private func configure(_ queue: LocalTriageQueue, sections: [FeedSection]) async {
        await queue.configure(coachingPlan: nil, forceOnboardingFeedLesson: false,
            sequentialFeed: true, calendarFeedDue: false, localCalendar: false, feedSections: sections)
    }
}

private actor SectionSource {
    var calls: [String] = []
    var failFirst: Bool
    init(failFirst: Bool = false) { self.failFirst = failFirst }
    func load(_ section: FeedSection) -> [LocalTriageQueue.Item]? {
        calls.append(section.id)
        if failFirst { failFirst = false; return nil }
        let account = section.account ?? ""
        return (0..<(account == "a@test.invalid" ? 6 : 20)).map { index in
            .init(account: account, id: "\(account)-\(index)", threadId: "t-\(index)", from: "Synthetic sender",
                subject: "Synthetic email \(index)", date: "", snippet: "Synthetic content",
                internalDate: Int64(Date().timeIntervalSince1970 * 1000), acted: nil)
        }
    }
}
