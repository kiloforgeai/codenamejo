import Foundation
import GRDB
import Testing

@testable import CodenameJo

/// The band-major walk, at the level it can be tested without a phone.
///
/// The ordering *decision* is graded in `MailImportanceTests`. What this suite covers is how a band
/// is stored, which rows a banded page returns, and — the one that matters most — that a
/// mailbox nothing has scored behaves exactly as it did before any of this existed.
@Suite struct MailImportanceOrderingTests {

    fileprivate static let account = "me@example.com"

    private struct Harness {
        let store: MailStore
        let database: DatabasePool
        let directory: URL

        /// One unread inbox message, `at` milliseconds on Gmail's clock.
        func seed(_ id: String, at internalDate: Int64) throws {
            try database.write { db in
                try MailStore.Message(
                    user_id: "test-user", id: id, account: MailImportanceOrderingTests.account,
                    threadId: "\(id)-thread", sender: "Sender <sender@example.com>",
                    recipient: MailImportanceOrderingTests.account, subject: id,
                    snippet: "preview", internalDate: internalDate,
                    cachedAt: Date(timeIntervalSince1970: 1)).insert(db)
                for label in ["INBOX", "UNREAD"] {
                    try MailStore.Label(
                        user_id: "test-user", messageId: id,
                        account: MailImportanceOrderingTests.account, label: label).insert(db)
                }
            }
        }
    }

    private func makeStore() throws -> Harness {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try DatabasePool(path: directory.appendingPathComponent("test.sqlite").path)
        try database.write { db in
            try MailStore.createUserScopedSchema(db)
            // The migrator layers these in the same order on a real install.
            try MailStore.addImportance(db)
        }
        return Harness(store: MailStore(database: database, userId: "test-user"),
                       database: database, directory: directory)
    }

    @Test func anUnscoredMailboxPagesExactlyAsItDidBefore() async throws {
        let h = try makeStore()
        let store = h.store
        defer { try? FileManager.default.removeItem(at: h.directory) }
        try h.seed("older", at: 1_000)
        try h.seed("newer", at: 2_000)

        #expect(await store.hasBands(account: Self.account) == false,
                "nothing is banded, so nothing asks for a banded walk")

        let page = await store.unreadPage(before: nil, limit: 12, account: Self.account)
        #expect(page.map(\.id) == ["newer", "older"], "and the page is newest-first, as it always was")
    }

    @Test func aBandedPageReturnsOnlyThatBand() async throws {
        let h = try makeStore()
        let store = h.store
        defer { try? FileManager.default.removeItem(at: h.directory) }
        try h.seed("urgent", at: 1_000)
        try h.seed("ordinary", at: 2_000)
        try h.seed("bulk", at: 3_000)
        await store.applyBands([
            "urgent": ("high", "needs the contract signed", nil),
            "bulk": ("low", "", nil),
        ], account: Self.account)

        #expect(await store.hasBands(account: Self.account) == true)

        let high = await store.unreadPage(before: nil, limit: 12, account: Self.account, band: "high")
        #expect(high.map(\.id) == ["urgent"])
        #expect(high.first?.importanceWhy == "needs the contract signed",
                "a top-band message carries the reason the model may say")

        let low = await store.unreadPage(before: nil, limit: 12, account: Self.account, band: "low")
        #expect(low.map(\.id) == ["bulk"])
    }

    /// The property the whole design rests on: a message nothing has scored is not stranded
    /// at the bottom and not promoted to the top — it is the middle band, and it is served.
    @Test func unscoredMailIsWalkedWithTheMiddleBand() async throws {
        let h = try makeStore()
        let store = h.store
        defer { try? FileManager.default.removeItem(at: h.directory) }
        try h.seed("urgent", at: 1_000)
        try h.seed("neverScored", at: 2_000)
        await store.applyBands(["urgent": ("high", "", nil)], account: Self.account)

        let normal = await store.unreadPage(
            before: nil, limit: 12, account: Self.account, band: MailImportance.unscoredBand)
        #expect(normal.map(\.id) == ["neverScored"],
                "an unbanded row answers to the middle band rather than to none")

        // Every message is in exactly one band, so walking all three walks the mailbox.
        var walked: [String] = []
        for band in MailImportance.walkOrder {
            walked += await store.unreadPage(
                before: nil, limit: 12, account: Self.account, band: band).map(\.id)
        }
        #expect(Set(walked) == ["urgent", "neverScored"], "the bands partition the pile")
        #expect(walked.count == 2, "and nothing is served twice")
        #expect(walked.first == "urgent", "with the top band first")
    }

    @Test func eachBandPagesOnItsOwnWatermark() async throws {
        let h = try makeStore()
        let store = h.store
        defer { try? FileManager.default.removeItem(at: h.directory) }
        for index in 0..<4 { try h.seed("high\(index)", at: Int64(1_000 + index)) }
        await store.applyBands(
            Dictionary(uniqueKeysWithValues: (0..<4).map {
                ("high\($0)", (band: "high", why: "", score: Int?.none))
            }),
            account: Self.account)

        let first = await store.unreadPage(before: nil, limit: 2, account: Self.account, band: "high")
        #expect(first.map(\.id) == ["high3", "high2"])
        // `before` is epoch seconds on the way in and milliseconds in the column, the same
        // conversion `fetchPage` does.
        let watermark = (first.last?.internalDate ?? 0)
        let second = await store.unreadPage(
            before: watermark, limit: 2, account: Self.account, band: "high")
        #expect(second.map(\.id) == ["high1", "high0"], "the second page of a band continues it")
    }

    @Test func aBandForAMessageWeDoNotHoldIsDropped() async throws {
        let h = try makeStore()
        let store = h.store
        defer { try? FileManager.default.removeItem(at: h.directory) }
        try h.seed("held", at: 1_000)
        await store.applyBands([
            "held": ("high", "needs a reply", nil),
            "neverCached": ("high", "invisible", nil),
        ], account: Self.account)

        let high = await store.unreadPage(before: nil, limit: 12, account: Self.account, band: "high")
        #expect(high.map(\.id) == ["held"],
                "a band cannot conjure a row with no sender, no subject and no labels")
    }

    @Test func unscoredReadsOnlyWhatStillNeedsClassification() async throws {
        let h = try makeStore()
        let store = h.store
        defer { try? FileManager.default.removeItem(at: h.directory) }
        try h.seed("done", at: 1_000)
        try h.seed("todo", at: 2_000)
        await store.applyBands(["done": ("low", "", nil)], account: Self.account)
        await store.applyTopics(["done": "done-topic"], version: 1, account: Self.account)

        let pending = await store.unscored(account: Self.account, limit: 60)
        #expect(pending.map(\.id) == ["todo"], "fully classified mail leaves the pending batch")
    }

    @Test func importanceAndTopicsCompleteIndependentlyAndMissingVerdictsRetry() async throws {
        let h = try makeStore()
        let store = h.store
        defer { try? FileManager.default.removeItem(at: h.directory) }
        try h.seed("needsTopic", at: 2_000)
        try h.seed("needsBand", at: 1_000)
        await store.applyBands(["needsTopic": ("low", "", nil)], account: Self.account)
        await store.applyTopics(["needsBand": "band-topic"], version: 1, account: Self.account)

        let pending = await store.unscored(account: Self.account, limit: 60)
        #expect(pending.map(\.id) == ["needsBand", "needsTopic"],
                "missing importance takes priority, but already-banded mail still needs a topic")

        await store.applyTopics([:], version: 1, account: Self.account)
        await store.applyTopics(["needsTopic": "unsupported"], version: 2, account: Self.account)
        let retry = await store.unscored(account: Self.account, limit: 60)
        #expect(retry.map(\.id) == pending.map(\.id),
                "missing and unsupported topic verdicts remain retryable")

        await store.applyTopics(["needsTopic": "topic"], version: 1, account: Self.account)
        let needsBand = await store.unscored(account: Self.account, limit: 60)
        #expect(needsBand.map(\.id) == ["needsBand"])
        await store.applyBands(["needsBand": ("normal", "", nil)], account: Self.account)
        #expect(await store.unscored(account: Self.account, limit: 60).isEmpty)
    }

    /// The score orders inside a band and can never lift a message out of one.
    @Test func theScoreOrdersWithinABandAndNeverAcrossOne() async throws {
        let h = try makeStore()
        let store = h.store
        defer { try? FileManager.default.removeItem(at: h.directory) }
        // The weakest top-band message is the OLDEST and lowest-scoring; the strongest
        // middle-band one is the NEWEST and highest-scoring. Only a correct sort separates
        // them, and date order alone would invert both pairs.
        try h.seed("weakHigh", at: 1_000)
        try h.seed("strongNormal", at: 4_000)
        try h.seed("weakNormal", at: 3_000)
        await store.applyBands([
            "weakHigh": ("high", "needs a reply", 1),
            "strongNormal": ("normal", "", 10),
            "weakNormal": ("normal", "", 2),
        ], account: Self.account)

        let high = await store.unreadPage(before: nil, limit: 12, account: Self.account, band: "high")
        #expect(high.map(\.id) == ["weakHigh"],
                "a 10 in the middle band cannot reach the top band")

        let normal = await store.unreadPage(before: nil, limit: 12, account: Self.account, band: "normal")
        #expect(normal.map(\.id) == ["strongNormal", "weakNormal"],
                "and inside a band the higher score leads, whatever the clock says")
    }

    /// An unscored message sorts last of its band, never first.
    @Test func unscoredSortsLastWithinItsBand() async throws {
        let h = try makeStore()
        let store = h.store
        defer { try? FileManager.default.removeItem(at: h.directory) }
        // The unscored one is the newest, so date order alone would put it first.
        try h.seed("scored", at: 1_000)
        try h.seed("neverScored", at: 9_000)
        await store.applyBands(["scored": ("normal", "", 4)], account: Self.account)

        let page = await store.unreadPage(
            before: nil, limit: 12, account: Self.account, band: MailImportance.unscoredBand)
        #expect(page.map(\.id) == ["scored", "neverScored"],
                "a message nothing has read does not lead the pile it landed in")
    }

    /// Paging a score-ordered band must not skip a low-scoring message that happens to be
    /// new. A date-only watermark does exactly that, which is why the cursor is the row
    /// value `(score, internalDate)`.
    @Test func pagingAScoreOrderedBandLosesNothing() async throws {
        let h = try makeStore()
        let store = h.store
        defer { try? FileManager.default.removeItem(at: h.directory) }
        // Scores descend as dates ASCEND, so the sort order and the clock disagree at every
        // step — under a date-only cursor the second page would be empty and four of six
        // messages would never be offered.
        let seeded = [("s9", 9, 1_000), ("s7", 7, 2_000), ("s5", 5, 3_000),
                      ("s4", 4, 4_000), ("s2", 2, 5_000), ("s1", 1, 6_000)]
        for (id, _, date) in seeded { try h.seed(id, at: Int64(date)) }
        await store.applyBands(
            Dictionary(uniqueKeysWithValues: seeded.map { ($0.0, (band: "normal", why: "", score: Int?($0.1))) }),
            account: Self.account)

        var walked: [String] = []
        var before: Int64? = nil
        var beforeScore: Int? = nil
        for _ in 0..<4 {
            let page = await store.unreadPage(
                before: before, limit: 2, account: Self.account,
                band: "normal", beforeScore: beforeScore)
            guard let last = page.last else { break }
            walked += page.map(\.id)
            before = last.internalDate
            beforeScore = last.importanceScore ?? 0
        }

        #expect(walked == ["s9", "s7", "s5", "s4", "s2", "s1"],
                "every message is offered exactly once, in score order, across page boundaries")
    }

    @Test func tiedScoresAndDatesPageWithoutLosingMessages() async throws {
        let h = try makeStore()
        defer { try? FileManager.default.removeItem(at: h.directory) }
        for id in ["a", "b", "c"] { try h.seed(id, at: 1_000) }
        await h.store.applyBands(Dictionary(uniqueKeysWithValues: ["a", "b", "c"].map {
            ($0, (band: "high", why: "reply", score: Int?(8)))
        }), account: Self.account)
        let first = await h.store.unreadPage(before: nil, limit: 2, account: Self.account, band: "high")
        let second = await h.store.unreadPage(
            before: first.last?.internalDate, limit: 2, account: Self.account,
            band: "high", beforeScore: 8, beforeID: first.last?.id)
        #expect((first + second).map(\.id) == ["c", "b", "a"])
    }

    @Test func resumeKeepsCurrentThenOrdersTheWholePendingPile() async throws {
        let h = try makeStore()
        defer { try? FileManager.default.removeItem(at: h.directory) }
        for (id, date) in [("current", 1), ("high", 2), ("low", 9), ("normal", 8)] {
            try h.seed(id, at: Int64(date))
        }
        await h.store.applyBands([
            "current": ("normal", "", 1), "high": ("high", "reply", 8),
            "low": ("low", "", 10), "normal": ("normal", "", 7),
        ], account: Self.account)
        let rows = await h.store.unreadPage(before: nil, limit: 100, account: Self.account, importanceOrder: true)
        #expect(rows.map(\.id) == ["high", "normal", "current", "low"])
        let items = rows.map { row in
            LocalTriageQueue.Item(account: row.account, id: row.id, threadId: row.threadId,
                from: "Sender", subject: row.id, date: "", snippet: "", internalDate: row.internalDate ?? 0)
        }
        let ordered = LocalTriageQueue.orderByImportance(Array(items.reversed()), rows: rows,
            currentID: "current", currentAccount: Self.account)
        #expect(ordered.map(\.id) == ["current", "high", "normal", "low"])
    }

    @Test func unbandedPagingStaysChronologicalEvenWithScores() async throws {
        let h = try makeStore()
        defer { try? FileManager.default.removeItem(at: h.directory) }
        try h.seed("older", at: 1_000)
        try h.seed("newer", at: 2_000)
        await h.store.applyBands(["older": ("high", "reply", 10)], account: Self.account)
        let page = await h.store.unreadPage(before: nil, limit: 1, account: Self.account)
        #expect(page.map(\.id) == ["newer"])
        let next = await h.store.unreadPage(before: page.last?.internalDate, limit: 1, account: Self.account)
        #expect(next.map(\.id) == ["older"])
    }

    // MARK: - The important scope's week (issue #982)

    private static let now = Int64(Date().timeIntervalSince1970 * 1000)
    private static let day: Int64 = 24 * 60 * 60 * 1000

    /// Any inbox-or-not message, for the week scope's filters.
    private func put(_ h: Harness, _ id: String, at internalDate: Int64, labels: [String] = ["INBOX"],
                     sender: String = "Sender <sender@example.com>", thread: String? = nil) throws {
        try h.database.write { db in
            try MailStore.Message(
                user_id: "test-user", id: id, account: Self.account,
                threadId: thread ?? "\(id)-thread", sender: sender,
                recipient: Self.account, subject: id, snippet: "preview", internalDate: internalDate,
                cachedAt: Date(timeIntervalSince1970: 1)).insert(db)
            for label in labels {
                try MailStore.Label(user_id: "test-user", messageId: id,
                                    account: Self.account, label: label).insert(db)
            }
        }
    }

    private func importantWalk(_ store: MailStore) async -> [String] {
        var walked: [String] = []
        for band in MailImportance.walkOrder {
            walked += await store.unreadPage(before: nil, limit: 50, importantOnly: true,
                                             account: Self.account, band: band).map(\.id)
        }
        return walked
    }

    @Test func theImportantScopeIsTheWeekReadOrUnread() async throws {
        let h = try makeStore()
        defer { try? FileManager.default.removeItem(at: h.directory) }
        try put(h, "unread", at: Self.now - Self.day, labels: ["INBOX", "UNREAD"])
        try put(h, "read", at: Self.now - 2 * Self.day)
        try put(h, "old", at: Self.now - 8 * Self.day, labels: ["INBOX", "UNREAD"])
        try put(h, "archived", at: Self.now - Self.day, labels: [])
        try put(h, "selfBare", at: Self.now - Self.day, sender: Self.account)
        try put(h, "selfNamed", at: Self.now - Self.day, sender: "Me <ME@example.com>")
        // Another address that merely ends in the account's is not the account.
        try put(h, "lookalike", at: Self.now - Self.day, sender: "Ome <ome@example.com>")
        try put(h, "bulk", at: Self.now - Self.day)
        await h.store.applyBands(["bulk": ("low", "", nil)], account: Self.account)

        let walked = await importantWalk(h.store)
        #expect(Set(walked) == ["unread", "read", "lookalike", "bulk"],
                "the week of the inbox, read mail and bulk included — not old, archived or self-sent")
        #expect(await h.store.importantCount(accounts: [Self.account]) == 4,
                "and the count is the same set")
        #expect(await h.store.importantIds(among: ["read", "old", "selfBare"]) == ["read"])
    }

    @Test func aThreadTheyAnsweredLeavesTheImportantScope() async throws {
        let h = try makeStore()
        defer { try? FileManager.default.removeItem(at: h.directory) }
        try put(h, "asked", at: Self.now - 3 * Self.day, thread: "t")
        try put(h, "reply", at: Self.now - 2 * Self.day, labels: ["SENT"], sender: Self.account, thread: "t")
        try put(h, "followUp", at: Self.now - Self.day, labels: ["INBOX", "UNREAD"], thread: "t")

        #expect(await importantWalk(h.store) == ["followUp"],
                "what they answered is out; what arrived after their answer is still in")
    }

    @Test func theImportantScopeWalksHighThenNormalByScore() async throws {
        let h = try makeStore()
        defer { try? FileManager.default.removeItem(at: h.directory) }
        try put(h, "unscored", at: Self.now - Self.day)
        try put(h, "normal", at: Self.now - 2 * Self.day)
        try put(h, "lowerHigh", at: Self.now - 3 * Self.day)
        try put(h, "topHigh", at: Self.now - 4 * Self.day)
        await h.store.applyBands([
            "normal": ("normal", "", 5), "lowerHigh": ("high", "a", 7), "topHigh": ("high", "b", 9),
        ], account: Self.account)

        #expect(await importantWalk(h.store) == ["topHigh", "lowerHigh", "normal", "unscored"])
    }

    @Test func readMailInTheWeekIsScoredButNotSelfSent() async throws {
        let h = try makeStore()
        defer { try? FileManager.default.removeItem(at: h.directory) }
        try put(h, "readRecent", at: Self.now - 2 * Self.day)
        try put(h, "readOld", at: Self.now - 9 * Self.day)
        try put(h, "unreadOld", at: Self.now - 9 * Self.day, labels: ["INBOX", "UNREAD"])
        try put(h, "selfNote", at: Self.now - Self.day, labels: ["INBOX", "UNREAD"], sender: Self.account)

        let pending = await h.store.unscored(account: Self.account, limit: 60)
        #expect(pending.map(\.id) == ["readRecent", "unreadOld"])
    }

    @Test func theInboxReconcileOnlyActsInsideTheWindow() async throws {
        let h = try makeStore()
        defer { try? FileManager.default.removeItem(at: h.directory) }
        try put(h, "listed", at: Self.now - Self.day)
        try put(h, "archivedElsewhere", at: Self.now - 2 * Self.day)
        try put(h, "olderThanTheWindow", at: Self.now - 10 * Self.day)

        let gone = await h.store.inboxIdsNotIn(["listed"], account: Self.account,
                                               since: MailStore.importantSince())
        #expect(gone == ["archivedElsewhere"])
        await h.store.clearInbox(gone)
        #expect(await importantWalk(h.store) == ["listed"])
    }

    @Test func theRankedListIsSpokenInFrontOfTheFirstMessage() {
        let step = #"{"ranked":[{"identity":"Priya","why":"needs the contract signed"},{"identity":"Resy"},{"identity":"Dana"}],"item":{}}"#
        #expect(FullDuplexVoiceClient.rankedLead(step)
                == "Three things matter most this week: Priya, needs the contract signed; Resy; and Dana. ")
        #expect(FullDuplexVoiceClient.rankedLead(#"{"ranked":[{"identity":"Priya"}],"item":{}}"#)
                == "One thing matters most this week: Priya. ", "a week always has a top")
        #expect(!FullDuplexVoiceClient.carriesRankedList(#"{"item":{"id":"a"}}"#))
    }

    @Test func aSenderWithSeveralRankedMessagesIsNamedOnce() {
        let step = #"{"ranked":[{"identity":"Priya","sender":"p@x.com|Priya","why":"needs the contract signed"},{"identity":"Dana","sender":"d@x.com|Dana"},{"identity":"Dana","sender":"d@x.com|Dana","why":"wants a reply"},{"identity":"Resy","sender":"r@x.com|Resy"},{"identity":"Dana","sender":"d@x.com|Dana"}],"item":{}}"#
        #expect(FullDuplexVoiceClient.rankedLead(step)
                == "Five things matter most this week: Priya, needs the contract signed; three from Dana; and Resy. ")
        #expect(FullDuplexVoiceClient.rankedLead(#"{"ranked":[{"identity":"Dana","sender":"d@x.com|Dana"},{"identity":"Dana","sender":"d@x.com|Dana"}],"item":{}}"#)
                == "Two things matter most this week, all from Dana. ")
    }

    @Test func aSharedLabelIsNotASharedSender() {
        let step = #"{"ranked":[{"identity":"Dana","sender":"d@x.com|Dana"},{"identity":"Dana","sender":"dana@y.com|Dana"},{"identity":"Your message to Sam"},{"identity":"Your message to Sam"}],"item":{}}"#
        #expect(FullDuplexVoiceClient.rankedLead(step)
                == "Four things matter most this week: Dana; Dana; Your message to Sam; and Your message to Sam. ")
    }

    @Test func theBandsAgreeWithTheBroker() {
        #expect(MailImportance.walkOrder == ["high", "normal", "low"],
                "the walk order is the broker's BANDS, and the two are one decision")
        #expect(MailImportance.walkOrder.contains(MailImportance.unscoredBand))
        #expect(MailImportance.walkOrder.firstIndex(of: MailImportance.unscoredBand) == 1,
                "unscored sits in the middle, so it is neither buried nor promoted")
    }
}
