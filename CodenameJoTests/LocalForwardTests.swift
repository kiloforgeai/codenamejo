// coverage-target: CodenameJo/Services/BackgroundRefresh/LocalForward.swift

import FactoryKit
import Foundation
import GRDB
import XCTest

@testable import CodenameJo

/// `forward_email` on the phone's own grant: which original it finds, what rides along and what is left behind,
/// drafts-only, the first-time recipient check, the standing rule and what happens after the receipt. Gmail, the
/// grant and the token are stubbed at the container; nothing reaches the Keychain or the network.
@MainActor
final class LocalForwardTests: XCTestCase {
    private let owner = "owner@example.test"
    private let work = "work@example.test"
    private var grants: ForwardGrantStorage!
    private var contacts: ContactStore!
    private var notices: LocalWriteNotices!
    private var paths: [String] = []

    private static let defaultsKeys = [StandingRule.archiveAfterForward.storageKey, MailFooter.storageKey,
                                       DraftsOnly.storageKey, DraftsOnly.byAccountStorageKey]

    override func setUp() async throws {
        try await super.setUp()
        grants = ForwardGrantStorage()
        let grants = grants!
        Container.shared.googleGrantStorage.register { grants }
        Container.shared.googleTokenProvider.register { MainActor.assumeIsolated { ForwardTokenProvider() } }
        Container.shared.mailStore.register { MailStore(database: nil, userId: "forward-tests") }
        connect(owner)
        let path = NSTemporaryDirectory() + "forward-\(UUID().uuidString).sqlite"
        paths.append(path)
        let pool = try DatabasePool(path: path)
        try await pool.write { try ContactStore.createSchema($0); try ContactStore.addSource($0) }
        contacts = ContactStore(database: pool)
        let contacts = contacts!
        Container.shared.contactStore.register { contacts }
        notices = LocalWriteNotices()
        let notices = notices!
        Container.shared.localWriteNotices.register { notices }
        Self.defaultsKeys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        UserDefaults.standard.set(false, forKey: DraftsOnly.storageKey)
        await contacts.recordSent(account: owner, email: "sam@acme.test")
    }

    override func tearDown() async throws {
        Container.shared.googleGrantStorage.reset()
        Container.shared.googleTokenProvider.reset()
        Container.shared.mailStore.reset()
        Container.shared.providerHTTP.reset()
        Container.shared.contactStore.reset()
        Container.shared.localWriteNotices.reset()
        Self.defaultsKeys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        paths.forEach { try? FileManager.default.removeItem(atPath: $0) }
        try await super.tearDown()
    }

    private func connect(_ email: String) {
        grants.store(GoogleAccountStore.Grant(email: email, refreshToken: "refresh", scopes:
            ["https://www.googleapis.com/auth/gmail.modify"], grantedAt: Date(), isPrimary: grants.all().isEmpty))
    }

    // MARK: - Gmail

    private struct Part {
        var filename: String
        var size: Int
        var attachmentId = ""
        var inline: String?
    }

    nonisolated private static func base64url(_ text: String) -> String {
        Data(text.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    }

    /// `messages.get?format=full` for the original: a plain body plus the given attachment parts.
    private func original(_ id: String, parts: [Part] = []) -> String {
        let headers = [["name": "From", "value": "Dana <dana@acme.test>"], ["name": "Subject", "value": "Q3 numbers"],
                       ["name": "Date", "value": "Tue, 25 Aug 2026 09:00:00 -0700"], ["name": "To", "value": owner],
                       ["name": "Message-ID", "value": "<\(id)@mail.test>"]]
        let attachments: [[String: Any]] = parts.map { part in
            var body: [String: Any] = ["size": part.size]
            if !part.attachmentId.isEmpty { body["attachmentId"] = part.attachmentId }
            if let inline = part.inline { body["data"] = Self.base64url(inline) }
            return ["mimeType": "application/octet-stream", "filename": part.filename, "body": body]
        }
        let payload: [String: Any] = ["mimeType": "multipart/mixed", "headers": headers, "parts":
            [["mimeType": "text/plain", "body": ["data": Self.base64url("The numbers.")]]] + attachments]
        let data = try! JSONSerialization.data(withJSONObject: ["id": id, "threadId": "T-\(id)", "payload": payload])
        return String(decoding: data, as: UTF8.self)
    }

    /// A Gmail where `holders` hold message `m1`, every write lands, and searches answer `hits`.
    @discardableResult
    private func gmail(parts: [Part] = [], holders: Set<String>? = nil, hits: [String] = [],
                       override: (@Sendable (ScriptedGmail.Call) -> (Int, String, String)?)? = nil) -> ScriptedGmail {
        let holders = holders ?? [owner]
        let messages = Dictionary(uniqueKeysWithValues: (["m1"] + hits).map { ($0, original($0, parts: parts)) })
        let scripted = ScriptedGmail { call in
            if let answer = override?(call) { return answer }
            let account = call.bearerToken.replacingOccurrences(of: "access-", with: "")
            switch (call.method, call.path) {
            case ("GET", "messages"): return (200, "application/json", ScriptedGmail.messageList(hits))
            case ("POST", "messages/send"): return (200, "application/json", #"{"id":"s1","threadId":"T-m1"}"#)
            case ("POST", "drafts"): return (200, "application/json", #"{"id":"d1"}"#)
            case ("POST", let path) where path.hasPrefix("threads/"):
                return (200, "application/json", #"{"id":"T-m1","messages":[{"id":"m1"}]}"#)
            case ("GET", let path) where path.contains("/attachments/"):
                return (200, "application/json", #"{"data":"\#(Self.base64url("bytes of \(path.split(separator: "/").last!)"))"}"#)
            case ("GET", let path) where path.hasPrefix("messages/"):
                let id = String(path.dropFirst("messages/".count))
                guard let body = messages[id], id != "m1" || holders.contains(account) else { return (404, "application/json", "{}") }
                return (200, "application/json", body)
            default: return (404, "application/json", "{}")
            }
        }
        Container.shared.providerHTTP.register { scripted }
        return scripted
    }

    private func run(_ args: [String: Any], defer deferred: Bool = false) async -> FullDuplexBroker.ToolResult {
        let data = try! JSONSerialization.data(withJSONObject: args)
        return await LocalForward.run(argumentsJSON: String(decoding: data, as: UTF8.self), defer: deferred,
                                      conversationId: "call")
    }

    private func posts(_ scripted: ScriptedGmail) -> [String] { scripted.calls.filter { $0.method == "POST" }.map(\.path) }

    /// The forward Gmail was handed, decoded.
    private func forwarded(_ scripted: ScriptedGmail) throws -> String {
        let call = try XCTUnwrap(scripted.calls.last { $0.path == "drafts" || $0.path == "messages/send" })
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(call.body.utf8)) as? [String: Any])
        let raw = try XCTUnwrap((json["message"] as? [String: Any] ?? json)["raw"] as? String)
        return String(decoding: try XCTUnwrap(GmailAPI.decodeBase64URL(raw)), as: UTF8.self)
    }

    // MARK: - Refusals

    func testEveryRefusalIsTheServersSentenceAndNothingIsSent() async {
        let scripted = gmail()
        let cases: [([String: Any], String)] = [
            (["message_id": "m1"], "No recipient — call find_person for the address, or ask the user."),
            (["message_id": "m1", "to": "Sam"], "Can't forward to \"Sam\" — that isn't an email address. Call find_person "
                + "for it, or ask the user. Nothing has gone yet."),
            (["message_id": "m1", "to": "sam@acme.test", "cc": (1...11).map { "p\($0)@acme.test" }], "That is 11 people "
                + "to copy, which is more than this should do in one go. Read the list back to the user and let them cut it."),
            (["to": "sam@acme.test"], "No message id or search given — say which message, or pass a `search` like "
                + "'from:stripe subject:\"Your receipt\"'."),
            (["message_id": "gone", "to": "sam@acme.test"], "That message id isn't in any connected account. Search for "
                + "the message first, then call this again with `search` set to a query that finds it."),
            (["message_id": "gone", "to": "sam@acme.test", "search": "from:nobody"], "Nothing matched \"from:nobody\". "
                + "Say what you searched."),
        ]
        for (args, expected) in cases {
            let result = await run(args)
            XCTAssertEqual(result.text, expected)
            XCTAssertEqual(result.ok, false)
        }
        XCTAssertTrue(posts(scripted).isEmpty)
    }

    // MARK: - What rides along

    func testAttachmentsUnderTheCapRideAlongAndTheRestAreNamedAsLeftBehind() async throws {
        let scripted = gmail(parts: [Part(filename: "invoice.pdf", size: 1_000, attachmentId: "a1"),
                                     Part(filename: "scan.tiff", size: 18_000_000, attachmentId: "a2"),
                                     Part(filename: "note.txt", size: 5, inline: "hello")])
        let result = await run(["message_id": "m1", "to": "sam@acme.test", "cc": ["lee@acme.test"]])
        XCTAssertEqual(result.text, "Forwarded to sam@acme.test from \(owner), copying lee@acme.test, without "
            + "scan.tiff (18.0 MB) — too big to send on.")
        XCTAssertEqual(result.ok, true)
        XCTAssertEqual(scripted.calls.filter { $0.path.contains("/attachments/") }.map(\.path), ["messages/m1/attachments/a1"],
                       "the inline part needs no fetch and the dropped one is never fetched")
        let message = try forwarded(scripted)
        XCTAssertTrue(message.contains("filename=\"invoice.pdf\"") && message.contains("filename=\"note.txt\""))
        XCTAssertFalse(message.contains("scan.tiff"))
        XCTAssertTrue(message.contains("Subject: Fwd: Q3 numbers"))
        let send = try XCTUnwrap(scripted.calls.first { $0.path == "messages/send" })
        XCTAssertTrue(send.body.contains(#""threadId":"T-m1""#), "the forward files into the original's thread")
    }

    func testTheOriginalIsFoundInTheMailboxThatHoldsItOrBySearch() async throws {
        connect(work)
        let held = gmail(holders: [work])
        await contacts.recordSent(account: work, email: "sam@acme.test")
        let fromWork = await run(["message_id": "m1", "to": "sam@acme.test"])
        XCTAssertEqual(fromWork.text, "Forwarded to sam@acme.test from \(work).")
        XCTAssertEqual(held.calls.first { $0.path == "messages/send" }?.bearerToken, "access-\(work)")

        let searched = gmail(holders: [], hits: ["h1"])
        let found = await run(["message_id": "m1", "to": "sam@acme.test", "search": "from:dana"])
        XCTAssertEqual(found.text, "Forwarded to sam@acme.test from \(owner).")
        XCTAssertEqual(searched.calls.first { $0.path == "messages" }?.query["maxResults"], "5")
        XCTAssertTrue(try forwarded(searched).contains("In-Reply-To: <h1@mail.test>"))
    }

    // MARK: - Drafts only, first-time recipients, the standing rule

    func testADraftsOnlyInboxSavesTheWholeForwardAsADraft() async throws {
        UserDefaults.standard.set(true, forKey: DraftsOnly.storageKey)
        let scripted = gmail(parts: [Part(filename: "invoice.pdf", size: 1_000, attachmentId: "a1")])
        let result = await run(["message_id": "m1", "to": "new@acme.test", "note": "FYI"])
        XCTAssertEqual(result.text, "Draft forward to new@acme.test saved in \(owner) — nothing was sent, because this "
            + "inbox is set to drafts only.")
        XCTAssertEqual(result.ok, true)
        XCTAssertEqual(posts(scripted), ["drafts"])
        XCTAssertFalse(scripted.calls.contains { $0.path == "messages" }, "a draft is not asked the first-time question")
        XCTAssertTrue(try forwarded(scripted).contains("filename=\"invoice.pdf\""), "a drafted forward is a whole forward")
    }

    func testAFirstTimeRecipientIsAskedAboutThenRemembered() async {
        gmail()
        let refused = await run(["message_id": "m1", "to": "new@acme.test"])
        XCTAssertEqual(refused.text, "NOT SENT — first time you've mailed new@acme.test. Ask the user \"is that the right "
            + "person?\" and if they say yes, call this again with recipient_confirmed: true. Nothing has gone yet.")
        let confirmed = await run(["message_id": "m1", "to": "new@acme.test", "recipient_confirmed": true])
        XCTAssertEqual(confirmed.text, "Forwarded to new@acme.test from \(owner).")
        let known = await contacts.hasCorresponded(email: "new@acme.test", accounts: [owner])
        XCTAssertTrue(known)
    }

    func testArchiveAfterForwardFilesTheOriginalsThreadAndSaysSoOnlyWhenGmailConfirms() async {
        UserDefaults.standard.set(true, forKey: StandingRule.archiveAfterForward.storageKey)
        let scripted = gmail()
        let filed = await run(["message_id": "m1", "to": "sam@acme.test"])
        XCTAssertEqual(filed.text, "Forwarded to sam@acme.test from \(owner). Archived.")
        XCTAssertEqual(posts(scripted), ["messages/send", "threads/T-m1/modify"])

        gmail { $0.path.hasPrefix("threads/") ? (500, "application/json", "{}") : nil }
        let unfiled = await run(["message_id": "m1", "to": "sam@acme.test"])
        XCTAssertEqual(unfiled.text, "Forwarded to sam@acme.test from \(owner). The automatic archive was not confirmed; "
            + "the mail may still be in the inbox.")
    }

    // MARK: - Failures

    func testFailuresSayNothingWentOutAndADeferredOneIsToldWithoutARetry() async throws {
        gmail(parts: [Part(filename: "invoice.pdf", size: 1_000, attachmentId: "a1")]) {
            $0.path.contains("/attachments/") ? (429, "application/json", "{}") : nil
        }
        let throttled = await run(["message_id": "m1", "to": "sam@acme.test"])
        XCTAssertEqual(throttled.text, "Gmail is rate-limiting this account right now. Nothing went out.")
        XCTAssertEqual(throttled.ok, false)

        let scripted = gmail { $0.path == "messages/send" ? (500, "application/json", "{}") : nil }
        let deferred = await run(["message_id": "m1", "to": "sam@acme.test"], defer: true)
        XCTAssertEqual(deferred.text, "Forwarded to sam@acme.test from \(owner).")
        XCTAssertTrue(deferred.deferred)
        var told = ""
        for _ in 0..<100 where told.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
            told = notices.appending(to: "", conversation: "call")
        }
        XCTAssertEqual(told, "\n\nthat didn't forward (gmail 500) — nothing went out, so it needs asking for again.")
        XCTAssertEqual(scripted.calls.filter { $0.path == "messages/send" }.count, 1)

        UserDefaults.standard.set(true, forKey: DraftsOnly.storageKey)
        gmail { $0.path == "drafts" ? (500, "application/json", "{}") : nil }
        let draft = await run(["message_id": "m1", "to": "sam@acme.test"])
        XCTAssertEqual(draft.text, "that draft forward didn't save (gmail 500) — there is nothing in \(owner)'s drafts, "
            + "so it needs asking for again.")
    }

    func testRunToolSendsForwardsHereAndDefersOnlyInsideACall() async {
        gmail()
        let inCall = await FullDuplexBroker.runTool(name: "forward_email",
            argumentsJSON: #"{"message_id":"m1","to":"sam@acme.test"}"#, conversationId: "call", deferSend: true)
        XCTAssertTrue(inCall.deferred)
        let noCall = await FullDuplexBroker.runTool(name: "forward_email",
            argumentsJSON: #"{"message_id":"m1","to":"sam@acme.test"}"#, deferSend: true)
        XCTAssertFalse(noCall.deferred)
        XCTAssertEqual(noCall.ok, true)
        let unknown = await FullDuplexBroker.runTool(name: "find_magic", argumentsJSON: "{}")
        XCTAssertEqual(unknown.ok, false)
    }
}

// MARK: - Harness

private final class ForwardTokenProvider: GoogleTokenProvider {

    func token(for email: String?, requiredScopes: [String]) async -> Result<GoogleCredential.Token, GoogleCredential.Failure> {
        guard let email else { return .failure(.noStoredGrant) }
        return .success(.init(accessToken: "access-\(email)", email: email, scopes: requiredScopes))
    }
}

private final class ForwardGrantStorage: GoogleGrantStorage, @unchecked Sendable {
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
