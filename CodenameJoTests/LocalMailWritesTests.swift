// coverage-target: CodenameJo/Services/BackgroundRefresh/LocalMailWrites.swift
// coverage-target: CodenameJo/Services/BackgroundRefresh/PendingMailWrites.swift

import FactoryKit
import Foundation
import GRDB
import XCTest

@testable import CodenameJo

/// Archive, trash, spam, label and count on the phone's own grant: which Gmail calls each makes, the label ids
/// it adds and removes, the receipts the queue handlers read, and the failure sentences the user hears.
/// Gmail, the grant and the token are stubbed at the container; nothing reaches the Keychain or the network.
@MainActor
final class LocalMailWritesTests: XCTestCase {
    private let owner = "owner@example.test"
    private let work = "work@example.test"
    private var grants: WritesGrantStorage!
    private var dbPath: String!

    override func setUp() async throws {
        try await super.setUp()
        grants = WritesGrantStorage()
        let grants = grants!
        Container.shared.googleGrantStorage.register { grants }
        Container.shared.googleTokenProvider.register { MainActor.assumeIsolated { WritesTokenProvider() } }
        Container.shared.mailStore.register { MailStore(database: nil, userId: "writes-tests") }
        connect(owner)
        UserDefaults.standard.removeObject(forKey: StandingRule.archiveAfterLabel.storageKey)
    }

    override func tearDown() async throws {
        Container.shared.googleGrantStorage.reset()
        Container.shared.googleTokenProvider.reset()
        Container.shared.mailStore.reset()
        Container.shared.providerHTTP.reset()
        Container.shared.pendingMailWrites.reset()
        Container.shared.localWriteNotices.reset()
        UserDefaults.standard.removeObject(forKey: StandingRule.archiveAfterLabel.storageKey)
        if let dbPath { try? FileManager.default.removeItem(atPath: dbPath) }
        try await super.tearDown()
    }

    private func connect(_ email: String) {
        grants.store(GoogleAccountStore.Grant(email: email, refreshToken: "refresh", scopes:
            ["https://www.googleapis.com/auth/gmail.modify"], grantedAt: Date(), isPrimary: grants.all().isEmpty))
    }

    /// A Gmail that accepts every modify and answers the reads below; `override` takes a call first.
    @discardableResult
    private func gmail(labels: [(String, String, String)] = [], override: (@Sendable (ScriptedGmail.Call) -> (Int, String, String)?)? = nil)
        -> ScriptedGmail {
        let labelJSON = labels.map { #"{"id":"\#($0.0)","name":"\#($0.1)","type":"\#($0.2)"}"# }.joined(separator: ",")
        let gmail = ScriptedGmail { call in
            if let answer = override?(call) { return answer }
            let parts = call.path.split(separator: "/").map(String.init)
            switch (call.method, parts.first, parts.last) {
            case ("POST", "messages", "modify"):
                return (200, "application/json", #"{"id":"\#(parts[1])","threadId":"thread-\#(parts[1])"}"#)
            case ("POST", "threads", "modify"):
                return (200, "application/json", #"{"id":"\#(parts[1])","messages":[{"id":"m1"}]}"#)
            case ("GET", "labels", "labels"): return (200, "application/json", #"{"labels":[\#(labelJSON)]}"#)
            case ("POST", "labels", "labels"): return (200, "application/json", #"{"id":"Label_new"}"#)
            default: return (404, "application/json", "{}")
            }
        }
        Container.shared.providerHTTP.register { gmail }
        return gmail
    }

    private func body(_ call: ScriptedGmail.Call) -> (add: [String], remove: [String]) {
        let json = (try? JSONSerialization.jsonObject(with: Data(call.body.utf8))) as? [String: Any] ?? [:]
        return (json["addLabelIds"] as? [String] ?? [], json["removeLabelIds"] as? [String] ?? [])
    }

    private func run(_ name: String, _ args: [String: Any], defer deferred: Bool = false,
                     conversation: String? = "call") async -> FullDuplexBroker.ToolResult {
        let data = try! JSONSerialization.data(withJSONObject: args)
        return await LocalMailWrites.run(name: name, argumentsJSON: String(decoding: data, as: UTF8.self),
                                         defer: deferred, conversationId: conversation)
    }

    private func writes(_ calls: ScriptedGmail) -> [ScriptedGmail.Call] {
        calls.calls.filter { $0.method == "POST" }
    }

    // MARK: - Which calls, which labels, which receipt

    func testArchiveTakesTheWholeThreadOutWhileSpamAndTrashTouchOnlyTheMessage() async {
        let scripted = gmail()
        let archived = await run("archive_message", ["message_id": "m1"])
        XCTAssertEqual(archived.text, "Archived in \(owner).")
        XCTAssertEqual(archived.ok, true)
        XCTAssertEqual(writes(scripted).map(\.path), ["messages/m1/modify", "threads/thread-m1/modify"])
        XCTAssertTrue(writes(scripted).allSatisfy { body($0).add.isEmpty && body($0).remove == ["INBOX", "UNREAD"] })
        XCTAssertEqual(archived.effects?.map(\.scope), ["message", "thread"])

        for (tool, label, receipt) in [("mark_spam", "SPAM", "Marked as spam in \(owner)."), ("trash_message", "TRASH", "Deleted in \(owner).")] {
            let scripted = gmail()
            let result = await run(tool, ["message_id": "m2"])
            XCTAssertEqual(result.text, receipt)
            XCTAssertEqual(result.ok, true)
            XCTAssertEqual(writes(scripted).map(\.path), ["messages/m2/modify"], tool)
            XCTAssertEqual(body(writes(scripted)[0]).add, [label])
            XCTAssertEqual(body(writes(scripted)[0]).remove, ["INBOX", "UNREAD"])
        }
    }

    func testEveryWriteNeedsAMessageId() async {
        let scripted = gmail()
        for tool in ["archive_message", "mark_spam", "trash_message"] {
            let result = await run(tool, [:])
            XCTAssertEqual(result.text, "No message id — search first, then act on a result.")
            XCTAssertEqual(result.ok, false)
        }
        let label = await run("label_message", ["label": "Receipts"])
        XCTAssertEqual(label.text, "No message id — search first, then act on a result.")
        XCTAssertTrue(scripted.calls.isEmpty)
    }

    // MARK: - Labels

    func testAnExistingLabelIsMatchedWithoutCaseAndLeavesTheMessageInTheInbox() async {
        let scripted = gmail(labels: [("Label_7", "Receipts", "user")])
        let result = await run("label_message", ["message_id": "m1", "label": "receipts"])
        XCTAssertEqual(result.text, "Labelled \"Receipts\" in \(owner).")
        XCTAssertEqual(writes(scripted).map(\.path), ["messages/m1/modify"])
        XCTAssertEqual(body(writes(scripted)[0]).add, ["Label_7"])
        XCTAssertEqual(body(writes(scripted)[0]).remove, ["UNREAD"])

        let archived = gmail(labels: [("Label_7", "Receipts", "user")])
        let filed = await run("label_message", ["message_id": "m1", "label": "Receipts", "also_archive": true])
        XCTAssertEqual(filed.text, "Labelled \"Receipts\" and archived in \(owner).")
        XCTAssertEqual(body(writes(archived)[0]).remove, ["INBOX", "UNREAD"])
        XCTAssertEqual(writes(archived).count, 1, "also_archive is message-wide; only the rule files the thread")
    }

    func testAMissingLabelIsCreatedAndASimilarOneIsOfferedBackUnlessANewOneWasAsked() async {
        let created = gmail()
        let made = await run("label_message", ["message_id": "m1", "label": "Taxes"])
        XCTAssertEqual(made.text, "Labelled \"Taxes\" in \(owner).")
        XCTAssertEqual(created.calls.filter { $0.method == "POST" }.map(\.path), ["labels", "messages/m1/modify"])
        XCTAssertEqual(body(writes(created)[1]).add, ["Label_new"])

        let similar = gmail(labels: [("Label_7", "Receipts 2026", "user"), ("CATEGORY_UPDATES", "CATEGORY_UPDATES", "system")])
        let refused = await run("label_message", ["message_id": "m1", "label": "receipts"])
        XCTAssertEqual(refused.text, "No label exactly named \"receipts\". Existing labels: \"Receipts 2026\". "
            + "Ask which one they mean before labelling.")
        XCTAssertEqual(refused.ok, false)
        XCTAssertTrue(writes(similar).isEmpty)

        let forced = gmail(labels: [("Label_7", "Receipts 2026", "user")])
        let new = await run("label_message", ["message_id": "m1", "label": "Receipts", "create_new": true])
        XCTAssertEqual(new.ok, true)
        XCTAssertEqual(writes(forced).map(\.path), ["labels", "messages/m1/modify"])
    }

    func testASystemLabelIsRefusedBeforeGmailIsAsked() async {
        let scripted = gmail()
        let result = await run("label_message", ["message_id": "m1", "label": "Spam"])
        XCTAssertTrue(result.text.hasPrefix("Spam is not a label."))
        XCTAssertTrue(scripted.calls.isEmpty)
    }

    func testTheStandingRuleFilesTheThreadAfterTheLabelLands() async {
        UserDefaults.standard.set(true, forKey: StandingRule.archiveAfterLabel.storageKey)
        let scripted = gmail(labels: [("Label_7", "Receipts", "user")])
        let result = await run("label_message", ["message_id": "m1", "label": "Receipts"])
        XCTAssertEqual(result.text, "Labelled \"Receipts\" and archived in \(owner).")
        XCTAssertEqual(writes(scripted).map(\.path), ["messages/m1/modify", "threads/thread-m1/modify"])
        XCTAssertEqual(body(writes(scripted)[0]).remove, ["UNREAD"], "the label write itself stays message-scoped")
        XCTAssertEqual(body(writes(scripted)[1]).remove, ["INBOX", "UNREAD"])
    }

    func testADeferredLabelAnswersFirstAndTellsTheConversationWhenItFails() async throws {
        let notices = LocalWriteNotices()
        Container.shared.localWriteNotices.register { notices }
        gmail(labels: [("Label_7", "Receipts", "user")]) { call in
            call.path == "messages/m1/modify" ? (500, "application/json", "{}") : nil
        }
        let result = await run("label_message", ["message_id": "m1", "label": "Receipts"], defer: true)
        XCTAssertEqual(result.text, "Labelled \"Receipts\" in \(owner).")
        XCTAssertTrue(result.deferred)
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(20))
            let told = notices.appending(to: "", conversation: "call")
            guard told.isEmpty else {
                return XCTAssertEqual(told, "\n\nthat didn't go through (gmail 500) — the label was not applied.")
            }
        }
        XCTFail("the deferred label's failure never reached the notice channel")
    }

    // MARK: - Which mailbox, and a dead id

    func testAnArchiveWithTwoInboxesGoesToTheOneThatHoldsTheMessage() async {
        connect(work)
        let scripted = gmail { call in
            guard call.method == "GET", call.path == "messages/m1" else { return nil }
            return call.bearerToken == "access-\(self.work)" ? (200, "application/json", #"{"id":"m1"}"#) : (404, "application/json", "{}")
        }
        let result = await run("archive_message", ["message_id": "m1"])
        XCTAssertEqual(result.text, "Archived in \(work).")
        XCTAssertTrue(writes(scripted).allSatisfy { $0.bearerToken == "access-\(work)" })

        let ambiguous = await run("mark_spam", ["message_id": "m1"])
        XCTAssertEqual(ambiguous.text, "Multiple accounts connected — ask the user which one, then pass `account`.")
    }

    func testADeadIdIsSearchedForAgainAndTheNewIdActedOn() async {
        let scripted = gmail { call in
            if call.path == "messages/dead/modify" { return (404, "application/json", "{}") }
            if call.method == "GET", call.path == "messages" { return (200, "application/json", ScriptedGmail.messageList(["fresh"])) }
            return nil
        }
        let result = await run("trash_message", ["message_id": "dead", "search": "from:a@example.test"])
        XCTAssertEqual(result.text, "Deleted in \(owner).")
        XCTAssertEqual(writes(scripted).map(\.path), ["messages/dead/modify", "messages/fresh/modify"])
        XCTAssertEqual(scripted.calls.first { $0.method == "GET" }?.query["q"], "from:a@example.test")
    }

    // MARK: - Failure sentences

    func testThrottleReauthorizationAndMissingIdEachSayWhatIsStillTrue() async {
        gmail { _ in (429, "application/json", "{}") }
        let throttled = await run("trash_message", ["message_id": "m1"])
        XCTAssertEqual(throttled.text, "Gmail is rate-limiting this account right now. The message is not in Trash.")
        XCTAssertEqual(throttled.ok, false)

        gmail { call in call.path.hasPrefix("threads/") ? (429, "application/json", "{}") : nil }
        let partial = await run("mark_spam", ["message_id": "m1"])
        XCTAssertEqual(partial.ok, true, "spam never makes the thread call")

        gmail { _ in (403, "application/json", #"{"error":"insufficientPermissions"}"#) }
        let reauth = await run("mark_spam", ["message_id": "m1"])
        XCTAssertEqual(reauth.text, "\(owner) needs reconnecting before it can archive, trash or label — its access predates "
            + "that permission. Remove and re-add the account in Settings, then try again.")

        gmail { call in call.path == "messages/nowhere/modify" ? (404, "application/json", "{}") : nil }
        let missing = await run("mark_spam", ["message_id": "nowhere"])
        XCTAssertEqual(missing.text, "that one didn't go through — the message id doesn't match anything in \(owner), so the "
            + "message is still in the inbox. Search for it by sender and subject and act on the id the search returns.")
        gmail { call in call.path == "messages/m1/modify" ? (404, "application/json", "{}") : nil }
        let label404 = await run("label_message", ["message_id": "m1", "label": "Taxes", "create_new": true])
        XCTAssertTrue(label404.text.contains("so the label was not applied."), label404.text)
    }

    func testAThreadThrottleOnAnArchiveSaysTheThreadWasNotFullyArchived() {
        XCTAssertEqual(LocalMailWrites.failure(GmailAPI.Failure.throttled, account: owner, operation: "archive_message",
                                               threadStep: true),
                       "Gmail is rate-limiting this account right now. The thread was not fully archived.")
        XCTAssertEqual(LocalMailWrites.failure(GmailAPI.Failure.http(500), account: owner, operation: "trash_message"),
                       "that didn't go through (gmail 500) — the message is not in Trash.")
    }

    // MARK: - count_messages

    func testTheQueueQueriesReadTheInboxCounterAndAnythingElseIsCounted() async throws {
        XCTAssertNotNil(LocalMailWrites.labelCounter(for: " IS:unread   in:inbox "))
        XCTAssertNotNil(LocalMailWrites.labelCounter(for: "in:inbox"))
        XCTAssertNil(LocalMailWrites.labelCounter(for: "is:unread"), "UNREAD's counter includes spam and trash")
        XCTAssertNil(LocalMailWrites.labelCounter(for: "in:inbox is:unread -from:me"))

        let scripted = gmail { call in
            switch call.path {
            case "labels/INBOX": return (200, "application/json", #"{"messagesUnread":7,"messagesTotal":40}"#)
            case "messages":
                let ids = (0..<500).map { "id\($0)" }
                return (200, "application/json", ScriptedGmail.messageList(call.query["q"] == "from:big" ? ids : ["a", "b"],
                                                                            nextPageToken: call.query["q"] == "from:big" ? "more" : nil))
            default: return nil
            }
        }
        func counted(_ query: String) async throws -> [String: Any] {
            let text = await run("count_messages", ["query": query]).text
            let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]])
            XCTAssertEqual(rows.first?["account"] as? String, owner)
            return try XCTUnwrap(rows.first?["result"] as? [String: Any])
        }
        let unread = try await counted("in:inbox is:unread")
        XCTAssertEqual(unread["count"] as? Int, 7)
        XCTAssertEqual(unread["atLeast"] as? Bool, false)
        XCTAssertFalse(scripted.calls.contains { $0.path == "messages" }, "the fast path lists no ids")
        let all = try await counted("in:inbox")
        XCTAssertEqual(all["count"] as? Int, 40)
        let some = try await counted("from:few")
        XCTAssertEqual(some["count"] as? Int, 2)
        XCTAssertEqual(some["atLeast"] as? Bool, false)
        let big = try await counted("from:big")
        XCTAssertEqual(big["count"] as? Int, 500)
        XCTAssertEqual(big["atLeast"] as? Bool, true)
    }

    // MARK: - Deferred archive, spam and trash

    private func queue(perform: @escaping PendingMailWrites.Perform = PendingMailWrites.gmail,
                       now: @escaping @Sendable () -> Date = Date.init) throws -> (PendingMailWrites, SettledLog) {
        dbPath = NSTemporaryDirectory() + "pending-\(UUID().uuidString).sqlite"
        let pool = try DatabasePool(path: dbPath)
        try pool.write { try PendingMailWrite.createSchema($0); try PendingMailWrite.addPayload($0) }
        let log = SettledLog()
        let queue = PendingMailWrites(dbPool: pool, perform: perform, settled: { job, outcome in log.add(job, outcome) }, now: now)
        return (queue, log)
    }

    func testADeferredArchiveIsQueuedBeforeGmailAndLandsWithTheDrain() async throws {
        let (writes, log) = try queue()
        Container.shared.pendingMailWrites.register { writes }
        let scripted = gmail()
        let result = await run("archive_message", ["message_id": "m1"], defer: true)
        XCTAssertEqual(result.ok, true)
        let pending = try XCTUnwrap(result.pendingArchive)
        XCTAssertEqual(pending.account, owner)
        XCTAssertEqual(pending.messageId, "m1")
        XCTAssertEqual(pending.operation, "archive_message")
        await writes.drain(userId: "")
        XCTAssertEqual(self.writes(scripted).map(\.path), ["messages/m1/modify", "threads/thread-m1/modify"])
        XCTAssertEqual(log.succeeded, 1)
        let status = await writes.status(userId: "")
        XCTAssertTrue(status.pending.isEmpty)
        XCTAssertEqual(status.succeeded?.map(\.messageId), ["m1"])
        XCTAssertEqual(status.succeeded?.first?.threadId, "thread-m1")
    }

    func testTheBackoffIsTheServersCurve() {
        XCTAssertEqual(PendingMailWritePolicy.delay(attempt: 1, random: 0), 2)
        XCTAssertEqual(PendingMailWritePolicy.delay(attempt: 3, random: 0.5), 12)
        XCTAssertEqual(PendingMailWritePolicy.delay(attempt: 30, random: 0), 15 * 60, "capped at fifteen minutes")
        XCTAssertEqual(PendingMailWritePolicy.delay(attempt: 30, random: 1), 30 * 60)
        XCTAssertEqual(PendingMailWritePolicy.delay(attempt: 1, retryAfter: 3600, random: 0), 3600, "Retry-After is a floor")
        XCTAssertTrue(PendingMailWritePolicy.isRetryable(GmailAPI.Failure.throttled))
        XCTAssertTrue(PendingMailWritePolicy.isRetryable(GmailAPI.Failure.http(503)))
        XCTAssertFalse(PendingMailWritePolicy.isRetryable(GmailAPI.Failure.http(404)))
        XCTAssertFalse(PendingMailWritePolicy.isRetryable(GmailAPI.Failure.unauthorized))
    }

    func testARetryableFailureGivesUpAfterTwelveAttemptsWithOneFailure() async throws {
        let clock = Clock()
        let attempts = Counter()
        let (writes, log) = try queue(perform: { _ in attempts.bump(); throw GmailAPI.Failure.throttled },
                                      now: { clock.now })
        _ = try await writes.enqueue(userId: "u", operation: "mark_spam", account: owner, messageId: "m1", conversationId: "call")
        for _ in 0..<20 {
            await writes.drain(userId: "u")
            clock.advance(15 * 60 * 2)
        }
        XCTAssertEqual(attempts.value, PendingMailWritePolicy.maxAttempts)
        XCTAssertEqual(log.failures, ["Gmail is rate-limiting this account right now. The message is still in the inbox."])
        let pending = await writes.pending(userId: "u")
        XCTAssertTrue(pending.isEmpty)
    }

    func testAWriteOlderThanADayIsGivenUpWithoutAnotherAttempt() async throws {
        let clock = Clock()
        let attempts = Counter()
        let (writes, log) = try queue(perform: { _ in attempts.bump(); throw GmailAPI.Failure.http(503) }, now: { clock.now })
        _ = try await writes.enqueue(userId: "u", operation: "trash_message", account: owner, messageId: "m1", conversationId: nil)
        await writes.drain(userId: "u")
        XCTAssertEqual(attempts.value, 1)
        clock.advance(PendingMailWritePolicy.maxAge)
        await writes.drain(userId: "u")
        XCTAssertEqual(attempts.value, 1, "an expired row is failed, not tried again")
        XCTAssertEqual(log.failures, ["that didn't go through (gmail 503) — the message is not in Trash."])
    }

    func testAnUnrecoverableFailureIsToldOnceAndNeverRetried() async throws {
        let attempts = Counter()
        let (writes, log) = try queue(perform: { _ in attempts.bump(); throw GmailAPI.Failure.http(404) })
        _ = try await writes.enqueue(userId: "u", operation: "archive_message", account: owner, messageId: "m1", conversationId: "call")
        await writes.drain(userId: "u")
        await writes.drain(userId: "u")
        XCTAssertEqual(attempts.value, 1)
        XCTAssertEqual(log.failures.count, 1)
        XCTAssertTrue(log.failures[0].hasPrefix("that one didn't go through — the message id doesn't match anything"))
    }

    func testDrainsDoNotOverlapAndAnAcceptedWriteIsNotQueuedTwice() async throws {
        let gate = Gate()
        let attempts = Counter()
        let (writes, log) = try queue(perform: { _ in
            attempts.bump()
            await gate.wait()
            return ([], nil)
        })
        let first = try await writes.enqueue(userId: "u", operation: "archive_message", account: owner, messageId: "m1", conversationId: nil)
        let again = try await writes.enqueue(userId: "u", operation: "archive_message", account: owner, messageId: "m1", conversationId: nil)
        XCTAssertEqual(first.id, again.id)
        async let one: Void = writes.drain(userId: "u")
        async let two: Void = writes.drain(userId: "u")
        try await Task.sleep(for: .milliseconds(100))
        gate.open()
        _ = await (one, two)
        XCTAssertEqual(attempts.value, 1)
        XCTAssertEqual(log.succeeded, 1)
    }

    func testAnotherUsersRowsAreNeitherReportedNorDrained() async throws {
        let attempts = Counter()
        let (writes, _) = try queue(perform: { _ in attempts.bump(); return ([], nil) })
        _ = try await writes.enqueue(userId: "someone-else", operation: "archive_message", account: owner, messageId: "m1", conversationId: nil)
        await writes.drain(userId: "u")
        let pending = await writes.pending(userId: "u")
        XCTAssertTrue(pending.isEmpty)
        XCTAssertEqual(attempts.value, 0)
    }

    func testANoticeIsDeliveredOnceAndOnlyToItsOwnConversation() {
        let notices = LocalWriteNotices()
        notices.push("first failed.", conversation: "call")
        notices.push("from an earlier call.", conversation: "earlier")
        notices.push("second failed.", conversation: "call")
        XCTAssertEqual(notices.appending(to: "Archived.", conversation: "call"), "Archived.\n\nfirst failed. second failed.")
        XCTAssertEqual(notices.appending(to: "Next.", conversation: "call"), "Next.")
        XCTAssertEqual(notices.appending(to: "Later.", conversation: "earlier"), "Later.", "an earlier call's notice is dropped")
    }
}

// MARK: - Harness

private final class SettledLog: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var succeeded = 0
    private(set) var failures: [String] = []

    func add(_ job: PendingMailWrite, _ outcome: PendingMailWrites.Outcome) {
        lock.lock()
        defer { lock.unlock() }
        switch outcome {
        case .succeeded: succeeded += 1
        case .failed(let sentence): failures.append(sentence)
        }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func bump() { lock.lock(); count += 1; lock.unlock() }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.lock(); defer { lock.unlock() }; return current }
    func advance(_ seconds: TimeInterval) { lock.lock(); current += seconds; lock.unlock() }
}

private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    func open() { lock.lock(); opened = true; lock.unlock() }
    func wait() async {
        while true {
            lock.lock()
            let done = opened
            lock.unlock()
            if done { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

private final class WritesTokenProvider: GoogleTokenProvider {

    func token(for email: String?, requiredScopes: [String]) async -> Result<GoogleCredential.Token, GoogleCredential.Failure> {
        guard let email else { return .failure(.noStoredGrant) }
        return .success(.init(accessToken: "access-\(email)", email: email, scopes: requiredScopes))
    }
}

private final class WritesGrantStorage: GoogleGrantStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var grants: [GoogleAccountStore.Grant] = []

    func store(_ grant: GoogleAccountStore.Grant) {
        lock.lock()
        grants.append(grant)
        lock.unlock()
    }

    func all() -> [GoogleAccountStore.Grant] {
        lock.lock()
        defer { lock.unlock() }
        return grants
    }

    func save(_ grant: GoogleAccountStore.Grant) -> Bool {
        store(grant)
        return true
    }

    func remove(_ email: String) {
        lock.lock()
        grants.removeAll { $0.email == email }
        lock.unlock()
    }

    func removeAll() {
        lock.lock()
        grants.removeAll()
        lock.unlock()
    }
}
