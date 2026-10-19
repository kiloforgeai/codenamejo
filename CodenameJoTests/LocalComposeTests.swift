// coverage-target: CodenameJo/Services/BackgroundRefresh/LocalCompose.swift

import FactoryKit
import Foundation
import GRDB
import XCTest

@testable import CodenameJo

/// `create_draft` and `send_email` on the phone's own grant: who a reply goes to, what it is copied to, the receipts the
/// queue reads, the refusals the model acts on, and what happens when Gmail says no after the receipt. Gmail, the grant
/// and the token are stubbed at the container; nothing reaches the Keychain or the network.
@MainActor
final class LocalComposeTests: XCTestCase {
    private let owner = "owner@example.test"
    private let work = "work@example.test"
    private let dana = "Dana Okafor <dana@acme.co>"
    private var grants: ComposeGrantStorage!
    private var contacts: ContactStore!
    private var writes: PendingMailWrites!
    private var writePool: DatabasePool!
    private var notices: LocalWriteNotices!
    private var settled: ComposeSettled!
    private var clock: ComposeClock!
    private var paths: [String] = []

    private static let defaultsKeys = [StandingRule.archiveAfterReply.storageKey, MailFooter.storageKey,
                                       DraftsOnly.storageKey, DraftsOnly.byAccountStorageKey]

    override func setUp() async throws {
        try await super.setUp()
        grants = ComposeGrantStorage()
        let grants = grants!
        Container.shared.googleGrantStorage.register { grants }
        Container.shared.googleTokenProvider.register { MainActor.assumeIsolated { ComposeTokenProvider() } }
        Container.shared.mailStore.register { MailStore(database: nil, userId: "compose-tests") }
        connect(owner)

        let contactPool = try pool()
        try await contactPool.write { try ContactStore.createSchema($0); try ContactStore.addSource($0) }
        contacts = ContactStore(database: contactPool)
        let contacts = contacts!
        Container.shared.contactStore.register { contacts }

        writePool = try pool()
        try await writePool.write { try PendingMailWrite.createSchema($0); try PendingMailWrite.addPayload($0) }
        clock = ComposeClock()
        settled = ComposeSettled()
        let clock = clock!, settled = settled!
        writes = PendingMailWrites(dbPool: writePool, settled: { job, outcome in settled.add(job, outcome) },
                                   now: { clock.now })
        let writes = writes!
        Container.shared.pendingMailWrites.register { writes }
        notices = LocalWriteNotices()
        let notices = notices!
        Container.shared.localWriteNotices.register { notices }

        Self.defaultsKeys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        UserDefaults.standard.set(false, forKey: DraftsOnly.storageKey)
    }

    override func tearDown() async throws {
        Container.shared.googleGrantStorage.reset()
        Container.shared.googleTokenProvider.reset()
        Container.shared.mailStore.reset()
        Container.shared.providerHTTP.reset()
        Container.shared.contactStore.reset()
        Container.shared.pendingMailWrites.reset()
        Container.shared.localWriteNotices.reset()
        Self.defaultsKeys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        paths.forEach { try? FileManager.default.removeItem(atPath: $0) }
        try await super.tearDown()
    }

    private func pool() throws -> DatabasePool {
        let path = NSTemporaryDirectory() + "compose-\(UUID().uuidString).sqlite"
        paths.append(path)
        return try DatabasePool(path: path)
    }

    private func connect(_ email: String) {
        grants.store(GoogleAccountStore.Grant(email: email, refreshToken: "refresh", scopes:
            ["https://www.googleapis.com/auth/gmail.modify"], grantedAt: Date(), isPrimary: grants.all().isEmpty))
    }

    // MARK: - Gmail

    /// One message on a thread, as `threads.get?format=metadata` returns it.
    private struct Mail {
        var id: String
        var labels: [String] = ["INBOX"]
        var from = ""
        var to = ""
        var cc = ""
        var replyTo = ""
        var subject = "Plans"
        var messageId: String { "<\(id)@mail.example>" }

        var json: [String: Any] {
            let headers = [("From", from), ("To", to), ("Cc", cc), ("Reply-To", replyTo), ("Subject", subject),
                           ("Message-ID", messageId)].filter { !$0.1.isEmpty }.map { ["name": $0.0, "value": $0.1] }
            return ["id": id, "threadId": "T1", "labelIds": labels, "payload": ["headers": headers]]
        }
    }

    private func threadJSON(_ mails: [Mail]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: ["id": "T1", "messages": mails.map(\.json)])
        return String(decoding: data, as: UTF8.self)
    }

    /// A Gmail that holds `thread` for the accounts in `holders`, accepts every write, and answers searches with `hits`.
    @discardableResult
    private func gmail(_ thread: [Mail] = [], holders: Set<String>? = nil, hits: [Mail] = [],
                       aliases: [String] = ["alias@example.test"],
                       override: (@Sendable (ScriptedGmail.Call) -> (Int, String, String)?)? = nil) -> ScriptedGmail {
        let threadBody = threadJSON(thread)
        let holders = holders ?? [owner, work]
        let searchHits = hits.map { ($0.id, threadJSON([$0])) }
        let sendAs = aliases.map { #"{"sendAsEmail":"\#($0)","verificationStatus":"accepted"}"# }.joined(separator: ",")
        let owner = owner
        let scripted = ScriptedGmail { call in
            if let answer = override?(call) { return answer }
            switch (call.method, call.path) {
            case ("GET", "threads/T1"):
                return holders.contains(call.bearerToken.replacingOccurrences(of: "access-", with: ""))
                    ? (200, "application/json", threadBody) : (404, "application/json", "{}")
            case ("POST", "drafts"): return (200, "application/json", #"{"id":"d1"}"#)
            case ("POST", "messages/send"): return (200, "application/json", #"{"id":"s1","threadId":"T1"}"#)
            case ("POST", "threads/T1/modify"): return (200, "application/json", #"{"id":"T1","messages":[{"id":"m1"}]}"#)
            case ("GET", "settings/sendAs"):
                return (200, "application/json", #"{"sendAs":[{"sendAsEmail":"\#(owner)","isPrimary":true},\#(sendAs)]}"#)
            case ("GET", "messages"): return (200, "application/json", ScriptedGmail.messageList(searchHits.map(\.0)))
            default:
                if call.method == "GET", call.path.hasPrefix("messages/"),
                   let hit = searchHits.first(where: { call.path == "messages/\($0.0)" }),
                   let message = (try? JSONSerialization.jsonObject(with: Data(hit.1.utf8)) as? [String: Any])?["messages"]
                    as? [[String: Any]], let only = message.first,
                   let data = try? JSONSerialization.data(withJSONObject: only) {
                    return (200, "application/json", String(decoding: data, as: UTF8.self))
                }
                return (404, "application/json", "{}")
            }
        }
        Container.shared.providerHTTP.register { scripted }
        return scripted
    }

    private func run(_ name: String, _ args: [String: Any], defer deferred: Bool = false,
                     onboardingReply: Bool = false) async -> FullDuplexBroker.ToolResult {
        let data = try! JSONSerialization.data(withJSONObject: args)
        return await LocalCompose.run(name: name, argumentsJSON: String(decoding: data, as: UTF8.self),
                                      defer: deferred, conversationId: "call", onboardingReply: onboardingReply)
    }

    private func posts(_ scripted: ScriptedGmail) -> [String] {
        scripted.calls.filter { $0.method == "POST" }.map(\.path)
    }

    /// The message Gmail was handed, decoded: its headers by name and its body.
    private func sent(_ scripted: ScriptedGmail) throws -> (headers: [String: String], body: String) {
        let call = try XCTUnwrap(scripted.calls.last { $0.path == "drafts" || $0.path == "messages/send" })
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(call.body.utf8)) as? [String: Any])
        let raw = try XCTUnwrap((json["message"] as? [String: Any] ?? json)["raw"] as? String)
        let text = String(decoding: try XCTUnwrap(GmailAPI.decodeBase64URL(raw)), as: UTF8.self)
        let parts = text.components(separatedBy: "\r\n\r\n")
        var headers: [String: String] = [:]
        for line in parts[0].components(separatedBy: "\r\n") {
            let pair = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            headers[pair[0]] = pair[1]
        }
        return (headers, parts.dropFirst().joined(separator: "\r\n\r\n"))
    }

    private func dealt(_ mails: Mail...) -> [Mail] { mails }

    // MARK: - Refusals, before anything reaches Gmail

    func testEveryRefusalIsTheServersSentenceAndNothingIsWritten() async {
        let scripted = gmail()
        let draftTo = { (extra: [String: Any]) in
            await self.run("create_draft", ["to": "a@example.co", "subject": "Hi", "body": "b"].merging(extra) { $1 })
        }
        let cases: [(FullDuplexBroker.ToolResult, String)] = [
            (await run("send_email", ["to": "someone", "subject": "Hi", "body": "b"]),
             "NOT SENT — \"someone\" is not an email address. These tools only write outgoing mail and can never read or "
                + "check anything. If you meant to reply to a message, pass its thread_id and leave the address out. If you "
                + "were answering a question about the mailbox, use the Gmail read tools — or tell the user plainly that you "
                + "could not."),
            (await run("create_draft", ["subject": "Hi", "body": "b"]),
             "NOT SAVED — \"\" is not an email address. These tools only write outgoing mail and can never read or check "
                + "anything. If you meant to reply to a message, pass its thread_id and leave the address out. If you were "
                + "answering a question about the mailbox, use the Gmail read tools — or tell the user plainly that you could not."),
            (await draftTo(["reply_message_id": "m1"]), "NOT SENT — reply_message_id requires its thread_id. Nothing has gone yet."),
            (await draftTo(["subject": " "]), "No subject — write a short one from the body and call this again."),
            (await draftTo(["cc": ["Sarah"]]), "Can't copy \"Sarah\" — that isn't an email address. Call find_person for it, "
                + "or ask, then try again with every cc address spelled out. Nothing has gone yet."),
            (await draftTo(["bcc": [5]]), "Couldn't read a bcc entry (5) — pass every address as text."),
            (await draftTo(["cc": 5]), "Couldn't read cc — pass the addresses as a list of text, or leave it out."),
            (await draftTo(["cc": (1...11).map { "p\($0)@example.co" }]), "That is 11 people to copy, which is more than this "
                + "should do in one go. Read the list back to the user and let them cut it."),
            (await draftTo(["user_request": "Block some time tomorrow to review this email"]),
             "NOT DRAFTED — the user's request is to block or schedule calendar time, not to write mail. Call "
                + "create_calendar_event and use the current email only as context for the event title or description. Omit "
                + "account to use the calendar matching the current inbox; ask only if no matching calendar is connected. Do "
                + "not call web_search. Nothing was saved."),
        ]
        for (result, expected) in cases {
            XCTAssertEqual(result.text, expected)
            XCTAssertEqual(result.ok, false)
        }
        XCTAssertTrue(posts(scripted).isEmpty)

        let mail = await draftTo(["user_request": "Reply and say I put it on my calendar"])
        XCTAssertEqual(mail.text, "Draft to a@example.co saved in \(owner).", "asking for mail wins over a calendar mention")
        XCTAssertEqual(LocalCompose.calendarRefusal("book a meeting with Dana  on  thursday"), LocalCompose.calendarRefusal(
            "Block some time tomorrow to review this email"))
        XCTAssertNil(LocalCompose.calendarRefusal("draft an email about our calendar"))
        for request in ["Can you block some time on my calendar at 4 PM to review this email?",
                        "I bought some time on my calendar tomorrow at 2 PM to accept this invite"] {
            XCTAssertNotNil(LocalCompose.calendarRefusal(request), request)
        }
    }

    // MARK: - Who a reply goes to

    func testAReplyGoesToTheNewestSenderUnderTheThreadsOwnSubjectAndThreading() async throws {
        let scripted = gmail(dealt(
            Mail(id: "m1", from: dana, to: owner, subject: "RE: re: Plans"),
            Mail(id: "m2", labels: ["SENT"], from: owner, to: dana, subject: "Re: Plans"),
            Mail(id: "m3", labels: ["DRAFT"], from: owner, to: dana, subject: "Re: Re: Plans")))
        let result = await run("create_draft", ["thread_id": "T1", "to": "wrong@elsewhere.co", "subject": "Lunch?",
                                                "body": "Yes."])
        XCTAssertEqual(result.text, "Draft to \(dana) saved in \(owner).", "the thread's answer beats an off-thread to")
        XCTAssertEqual(result.ok, true)
        let message = try sent(scripted)
        XCTAssertEqual(message.headers["To"], dana, "the display name is kept")
        XCTAssertEqual(message.headers["Subject"], "Re: Plans", "the thread's subject, its Re: prefixes collapsed to one")
        XCTAssertEqual(message.headers["In-Reply-To"], "<m2@mail.example>", "the newest delivered message, not the draft")
        XCTAssertEqual(message.headers["References"], "<m2@mail.example>", "the one Message-ID, not a chain")
        XCTAssertNil(message.headers["Cc"], "the user is never copied on their own reply")
        let call = try XCTUnwrap(scripted.calls.first { $0.path == "drafts" })
        XCTAssertTrue(call.body.contains(#""threadId":"T1""#))
    }

    func testTheSelectedMessageOrANamedParticipantIsWhoTheReplyAnswers() async throws {
        let thread = dealt(Mail(id: "m1", from: dana, to: owner),
                           Mail(id: "m2", from: "Sam Lee <sam@acme.co>", to: owner, replyTo: "list@acme.co"))
        var scripted = gmail(thread)
        let selected = await run("create_draft", ["thread_id": "T1", "reply_message_id": "m1", "body": "Hi Dana"])
        XCTAssertEqual(selected.text, "Draft to \(dana) saved in \(owner).")
        XCTAssertEqual(try sent(scripted).headers["In-Reply-To"], "<m1@mail.example>")

        scripted = gmail(thread)
        let named = await run("create_draft", ["thread_id": "T1", "to": "SAM@acme.co", "body": "Hi Sam"])
        XCTAssertEqual(named.text, "Draft to list@acme.co saved in \(owner).", "matched on From, answered at Reply-To")
        XCTAssertEqual(try sent(scripted).headers["In-Reply-To"], "<m2@mail.example>")

        scripted = gmail(thread)
        let newest = await run("create_draft", ["thread_id": "T1", "body": "Hi all"])
        XCTAssertEqual(newest.text, "Draft to list@acme.co saved in \(owner).", "Reply-To beats From")

        gmail(thread)
        let missing = await run("create_draft", ["thread_id": "T1", "reply_message_id": "nope", "body": "x"])
        XCTAssertEqual(missing.text, "NOT SENT — that selected message is not available in this thread and mailbox. "
            + "Nothing has gone yet.")
    }

    func testAThreadWhoseOnlyReplyAddressIsTheUserIsRefusedUntilAnAddressIsGiven() async throws {
        let thread = dealt(Mail(id: "m1", labels: ["SENT"], from: owner, to: "Me <\(owner)>"))
        gmail(thread)
        let refused = await run("send_email", ["thread_id": "T1", "body": "x"])
        XCTAssertEqual(refused.text, "NOT SENT — that thread's only reply address is your own (\(owner)), which is almost "
            + "never who a reply is for. Ask the user who it should go to, or call find_person, and call this again with an "
            + "explicit to. Nothing has gone yet.")

        // The model's own address is then not vouched for by the thread, so a send asks first.
        let scripted = gmail(thread)
        let asked = await run("send_email", ["thread_id": "T1", "to": "new@example.co", "body": "x"])
        XCTAssertTrue(asked.text.hasPrefix("NOT SENT — first time you've mailed new@example.co."), asked.text)
        XCTAssertFalse(posts(scripted).contains("messages/send"))
    }

    func testAFollowUpOnTheUsersOwnSentMailGoesToItsOutsideRecipients() async throws {
        connect(work)
        let group = Mail(id: "s1", labels: ["SENT"], from: "You <\(owner)>",
                         to: "\(owner), Amelie <amelie@example.test>, Priya <priya@example.test>, \(work)",
                         cc: "Vivek <vivek@example.test>, amelie@example.test")
        let scripted = gmail(dealt(group), holders: [owner])
        let result = await run("create_draft", ["thread_id": "T1", "reply_message_id": "s1", "body": "Just following up."])
        XCTAssertEqual(result.text, "Draft to Amelie <amelie@example.test> saved in \(owner), copying Priya "
            + "<priya@example.test> and Vivek <vivek@example.test>.")
        let headers = try sent(scripted).headers
        XCTAssertEqual(headers["To"], "Amelie <amelie@example.test>", "the first outside recipient, never a connected inbox")
        XCTAssertEqual(headers["Cc"], "Priya <priya@example.test>, Vivek <vivek@example.test>", "everyone else, once")
        XCTAssertEqual(headers["In-Reply-To"], "<s1@mail.example>")
    }

    func testAnUnsentDraftIsNeverWhoAReplyGoesToOrWhatItAnswers() async {
        let draft = Mail(id: "d1", labels: ["DRAFT"], from: "You <\(owner)>", to: "dana@acme.co")
        gmail(dealt(draft))
        let alone = await run("send_email", ["thread_id": "T1", "body": "x"])
        XCTAssertTrue(alone.text.hasPrefix("NOT SENT — that thread's only reply address is your own"), alone.text)

        gmail(dealt(Mail(id: "m1", from: dana, to: owner), draft))
        let selected = await run("create_draft", ["thread_id": "T1", "reply_message_id": "d1", "body": "x"])
        XCTAssertEqual(selected.text, "NOT SENT — that selected message is not available in this thread and mailbox. "
            + "Nothing has gone yet.", "a draft is not a message that can be followed up")
    }

    func testANamedSendersInboundMessageBeatsANewerSentOneAndItsCopiesComeWithIt() async throws {
        let inbound = Mail(id: "m1", from: dana, to: owner, cc: "inbound-copy@example.test")
        let followUp = Mail(id: "m2", labels: ["SENT"], from: "You <\(owner)>", to: dana, cc: "sent-copy@example.test")
        var scripted = gmail(dealt(inbound, followUp))
        _ = await run("send_email", ["thread_id": "T1", "body": "x"])
        XCTAssertEqual(try sent(scripted).headers["Cc"], "inbound-copy@example.test")

        scripted = gmail(dealt(inbound, followUp))
        _ = await run("send_email", ["thread_id": "T1", "to": "dana@acme.co", "body": "x"])
        let headers = try sent(scripted).headers
        XCTAssertEqual(headers["In-Reply-To"], "<m1@mail.example>", "the named person's own message, not the newer sent one")
        XCTAssertEqual(headers["Cc"], "inbound-copy@example.test")
    }

    func testOnlyVerifiedAliasesAreLeftOffAndAFailedAliasLookupSendsNothing() async throws {
        let inbound = Mail(id: "m1", from: dana, to: "Sales <SALES@example.test>, other@external.test",
                           cc: "pending@external.test")
        var scripted = gmail(dealt(inbound), aliases: ["sales@example.test"]) { call in
            guard call.path == "settings/sendAs" else { return nil }
            return (200, "application/json", #"{"sendAs":[{"sendAsEmail":"sales@example.test","verificationStatus":"accepted"},"#
                + #"{"sendAsEmail":"pending@external.test","verificationStatus":"pending"}]}"#)
        }
        _ = await run("send_email", ["thread_id": "T1", "body": "x"])
        XCTAssertEqual(try sent(scripted).headers["Cc"], "other@external.test, pending@external.test")
        XCTAssertEqual(scripted.calls.filter { $0.path == "settings/sendAs" }.count, 1)

        scripted = gmail(dealt(inbound)) { $0.path == "settings/sendAs" ? (503, "application/json", "{}") : nil }
        let failed = await run("send_email", ["thread_id": "T1", "body": "x"])
        XCTAssertEqual(failed.text, "The send_email call failed: gmail 503")
        XCTAssertFalse(posts(scripted).contains("messages/send"), "never an unfiltered reply-all")

        scripted = gmail(dealt(inbound)) { $0.path == "settings/sendAs" ? (503, "application/json", "{}") : nil }
        let single = await run("send_email", ["thread_id": "T1", "reply_all": false, "body": "x"])
        XCTAssertEqual(single.text, "Sent to \(dana) from \(owner).", "a reply to one person never needs the lookup")
    }

    // MARK: - Copies

    func testReplyAllCopiesTheAnsweredMessageLessTheUserTheirAliasesAndAnyoneAlreadyOn() async throws {
        connect(work)
        let thread = dealt(Mail(id: "m1", from: dana, to: "\(owner), \"Lee, Pat\" <pat@acme.co>, alias@example.test",
                                cc: "Sam@acme.co, \(work)"),
                           Mail(id: "m2", from: "Other <other@acme.co>", to: "\(owner), zed@acme.co"))
        let scripted = gmail(thread, holders: [owner])
        let result = await run("send_email", ["thread_id": "T1", "reply_message_id": "m1", "cc": ["sam@acme.co"],
                                              "bcc": "boss@acme.co, DANA@acme.co", "body": "Agreed."])
        XCTAssertEqual(result.text, "Sent to \(dana) from \(owner), copying sam@acme.co and \"Lee, Pat\" <pat@acme.co>, "
            + "blind copying boss@acme.co.")
        let headers = try sent(scripted).headers
        XCTAssertEqual(headers["Cc"], "sam@acme.co, \"Lee, Pat\" <pat@acme.co>", "the answered message's entries as written")
        XCTAssertEqual(headers["Bcc"], "boss@acme.co", "the recipient is never blind copied")
        XCTAssertTrue(scripted.calls.contains { $0.path == "settings/sendAs" })

        let alone = gmail(thread, holders: [owner])
        _ = await run("send_email", ["thread_id": "T1", "reply_message_id": "m1", "reply_all": false, "body": "Just you."])
        XCTAssertNil(try sent(alone).headers["Cc"])
        XCTAssertFalse(alone.calls.contains { $0.path == "settings/sendAs" }, "no one left to copy, no alias read")
    }

    // MARK: - Drafts only, and the first-time check

    func testOnboardingReplySendsWithoutChangingTheDraftPreference() async throws {
        DraftsOnly.set(true, for: owner)
        let scripted = gmail(dealt(Mail(id: "m1", from: dana, to: owner)))
        let result = await run("send_email", ["thread_id": "T1", "body": "Loved it."], onboardingReply: true)
        XCTAssertEqual(result.ok, true)
        XCTAssertEqual(result.text, "Sent to \(dana) from \(owner).")
        XCTAssertEqual(posts(scripted), ["messages/send"])
        XCTAssertTrue(DraftsOnly.isOn(for: owner))

        let later = gmail(dealt(Mail(id: "m1", from: dana, to: owner)))
        _ = await run("send_email", ["thread_id": "T1", "body": "One more thing."])
        XCTAssertEqual(posts(later), ["drafts"], "later replies still obey the saved preference")
    }

    func testADraftsOnlyInboxSavesTheSendAsADraftAndSaysNothingWent() async throws {
        UserDefaults.standard.set(true, forKey: DraftsOnly.storageKey)
        UserDefaults.standard.set(true, forKey: StandingRule.archiveAfterReply.storageKey)
        let scripted = gmail(dealt(Mail(id: "m1", from: dana, to: owner)))
        let result = await run("send_email", ["thread_id": "T1", "body": "Sounds good."])
        XCTAssertEqual(result.text, "Draft to \(dana) saved in \(owner). Archived. Nothing was sent because this inbox is "
            + "set to drafts only.")
        XCTAssertEqual(result.ok, true)
        XCTAssertEqual(result.performedTool, "create_draft")
        XCTAssertEqual(posts(scripted), ["drafts", "threads/T1/modify"])

        let fresh = gmail()
        let new = await run("send_email", ["to": "new@example.co", "subject": "Hi", "body": "x"])
        XCTAssertEqual(new.text, "Draft to new@example.co saved in \(owner). Nothing was sent because this inbox is set to "
            + "drafts only.", "a drafts-only inbox is not asked the first-time question")
        XCTAssertFalse(fresh.calls.contains { $0.path == "messages" })
    }

    func testAFirstTimeRecipientIsAskedAboutOnceAndRememberedAfterTheSend() async throws {
        var scripted = gmail()
        let first = await run("send_email", ["to": "New Person <new@example.co>", "subject": "Hi", "body": "x"])
        XCTAssertEqual(first.text, "NOT SENT — first time you've mailed New Person <new@example.co>. Ask the user \"is that "
            + "the right person?\" and if they say yes, call this again with recipient_confirmed: true. Nothing has gone yet.")
        XCTAssertEqual(scripted.calls.first { $0.path == "messages" }?.query["q"], #"from:"new@example.co" OR to:"new@example.co""#)

        scripted = gmail()
        let confirmed = await run("send_email", ["to": "New Person <new@example.co>", "subject": "Hi", "body": "x",
                                                 "recipient_confirmed": true])
        XCTAssertEqual(confirmed.text, "Sent to New Person <new@example.co> from \(owner).")
        XCTAssertEqual(confirmed.ok, true)
        let known = await contacts.hasCorresponded(email: "new@example.co", accounts: [owner])
        XCTAssertTrue(known, "the send bumps sentTo for the bare address")

        scripted = gmail()
        let again = await run("send_email", ["to": "new@example.co", "subject": "Hi again", "body": "x"])
        XCTAssertEqual(again.text, "Sent to new@example.co from \(owner).")
        XCTAssertFalse(scripted.calls.contains { $0.path == "messages" }, "the directory answered; Gmail was not searched")
    }

    func testOnlyAConnectedMailboxsHistoryOrAnExactGmailMatchCounts() async {
        await contacts.recordSent(account: "gone@example.test", email: "ghost@example.co")
        gmail()
        let ghost = await run("send_email", ["to": "ghost@example.co", "subject": "Hi", "body": "x"])
        XCTAssertTrue(ghost.text.hasPrefix("NOT SENT — first time"), "a disconnected mailbox's row does not vouch")

        gmail(hits: [Mail(id: "h1", from: "Ann <ann@example.co>", to: owner)])
        let ann = await run("send_email", ["to": "ann@example.co", "subject": "Hi", "body": "x"])
        XCTAssertEqual(ann.text, "Sent to ann@example.co from \(owner).")

        gmail(hits: [Mail(id: "h2", from: "Bo <bo@example.co.uk>", to: owner)])
        let near = await run("send_email", ["to": "bo@example.co", "subject": "Hi", "body": "x"])
        XCTAssertTrue(near.text.hasPrefix("NOT SENT — first time"), "only an exact address counts")
    }

    func testAReplyToTheThreadsOwnSenderSkipsTheFirstTimeCheck() async {
        let scripted = gmail(dealt(Mail(id: "m1", from: dana, to: owner)))
        let result = await run("send_email", ["thread_id": "T1", "body": "Thanks!"])
        XCTAssertEqual(result.text, "Sent to \(dana) from \(owner).")
        XCTAssertFalse(scripted.calls.contains { $0.path == "messages" })
    }

    // MARK: - The body, the footer, the standing rule

    func testTheBodyGoesOutExactlyAsWrittenWithTheFooterOnlyWhenItIsOn() async throws {
        await contacts.recordSent(account: owner, email: "dana@acme.co")
        let body = "hey  — u ok?\n\nthx, D\n"
        var scripted = gmail()
        _ = await run("send_email", ["to": "dana@acme.co", "subject": "Quick one", "body": body])
        XCTAssertEqual(try sent(scripted).body, body)

        UserDefaults.standard.set(true, forKey: MailFooter.storageKey)
        scripted = gmail()
        _ = await run("create_draft", ["to": "dana@acme.co", "subject": "Quick one", "body": body])
        XCTAssertEqual(try sent(scripted).body, body + "\n\nSent via Codename Jo 🪩 https://codenamejo.com")
    }

    func testTheStandingRuleFilesARepliedThreadAndSaysSoOnlyWhenGmailConfirms() async {
        UserDefaults.standard.set(true, forKey: StandingRule.archiveAfterReply.storageKey)
        let thread = dealt(Mail(id: "m1", from: dana, to: owner))
        let scripted = gmail(thread)
        let sent = await run("send_email", ["thread_id": "T1", "body": "Done."])
        XCTAssertEqual(sent.text, "Sent to \(dana) from \(owner). Archived.")
        XCTAssertEqual(posts(scripted), ["messages/send", "threads/T1/modify"])
        XCTAssertEqual(sent.effects?.first?.removeLabelIds, ["INBOX", "UNREAD"])
        XCTAssertEqual(sent.effects?.first?.scope, "thread")

        gmail(thread) { $0.path == "threads/T1/modify" ? (500, "application/json", "{}") : nil }
        let unfiled = await run("create_draft", ["thread_id": "T1", "body": "Draft."])
        XCTAssertEqual(unfiled.text, "Draft to \(dana) saved in \(owner). The automatic archive was not confirmed; the mail "
            + "may still be in the inbox.")
        XCTAssertEqual(unfiled.ok, true, "the draft itself landed")

        let fresh = gmail()
        await contacts.recordSent(account: owner, email: "dana@acme.co")
        let new = await run("send_email", ["to": "dana@acme.co", "subject": "Hi", "body": "x"])
        XCTAssertEqual(new.text, "Sent to dana@acme.co from \(owner).", "a fresh message has nothing to file")
        XCTAssertEqual(posts(fresh), ["messages/send"])
    }

    // MARK: - Which mailbox

    func testAReplyGoesFromTheMailboxThatHoldsTheThreadAndANewMessageFromTheLeadInbox() async throws {
        connect(work)
        let scripted = gmail(dealt(Mail(id: "m1", from: dana, to: work)), holders: [work])
        let reply = await run("create_draft", ["thread_id": "T1", "body": "Yes."])
        XCTAssertEqual(reply.text, "Draft to \(dana) saved in \(work).")
        XCTAssertEqual(scripted.calls.first { $0.path == "drafts" }?.bearerToken, "access-\(work)")

        gmail()
        let fresh = await run("create_draft", ["to": "dana@acme.co", "subject": "Hi", "body": "x"])
        XCTAssertEqual(fresh.text, "Draft to dana@acme.co saved in \(owner).")

        gmail(holders: [])
        let lost = await run("create_draft", ["thread_id": "T1", "body": "x"])
        XCTAssertEqual(lost.text, "Couldn't find thread T1 in any connected account. Ask the user which account to use and "
            + "pass `account`.")
    }

    // MARK: - After the receipt

    func testADeferredSendAnswersFirstAndAFailureIsToldOnceAndNeverRetried() async throws {
        await contacts.recordSent(account: owner, email: "dana@acme.co")
        let scripted = gmail { $0.path == "messages/send" ? (500, "application/json", "{}") : nil }
        let result = await run("send_email", ["to": "dana@acme.co", "subject": "Hi", "body": "x"], defer: true)
        XCTAssertEqual(result.text, "Sent to dana@acme.co from \(owner).")
        XCTAssertTrue(result.deferred)
        let told = try await notice()
        XCTAssertEqual(told, "\n\nthat didn't send (gmail 500) — nothing went out, so it needs asking for again.")
        XCTAssertEqual(scripted.calls.filter { $0.path == "messages/send" }.count, 1)
        let queued = await writes.pending(userId: "")
        XCTAssertTrue(queued.isEmpty)

        gmail { _ in (429, "application/json", "{}") }
        let throttled = await run("send_email", ["to": "dana@acme.co", "subject": "Hi", "body": "x"])
        XCTAssertEqual(throttled.text, "Gmail is rate-limiting this account right now. Nothing went out.")
        XCTAssertEqual(throttled.ok, false)
    }

    func testADraftThatFailsForAnotherReasonSaysThereIsNothingInDrafts() async {
        gmail { $0.path == "drafts" ? (500, "application/json", "{}") : nil }
        let result = await run("create_draft", ["to": "dana@acme.co", "subject": "Hi", "body": "x"])
        XCTAssertEqual(result.text, "that draft didn't save (gmail 500) — there is nothing in \(owner)'s drafts, so it "
            + "needs asking for again.")
        XCTAssertEqual(result.ok, false)
    }

    func testAThrottledDraftIsQueuedAndTheDrainSavesTheSameMessageWithoutFilingTheThread() async throws {
        UserDefaults.standard.set(true, forKey: StandingRule.archiveAfterReply.storageKey)
        let throttle = ComposeOnce()
        let scripted = gmail(dealt(Mail(id: "m1", from: dana, to: owner))) { call in
            call.path == "drafts" && throttle.first() ? (429, "application/json", "{}") : nil
        }
        let result = await run("create_draft", ["thread_id": "T1", "body": "On it."])
        XCTAssertEqual(result.text, "Drafting. The draft is queued for background retry. The message it answers was not "
            + "filed. Say that it is drafting, and say the filing clause above if there is one; then continue. Do not wait "
            + "or claim it has been saved.")
        XCTAssertEqual(result.ok, false)
        let pending = try XCTUnwrap(result.pendingDraft)
        XCTAssertEqual(pending.account, owner)
        XCTAssertEqual(pending.to, dana)
        XCTAssertEqual(pending.threadId, "T1")
        let archives = await writes.pending(userId: "")
        XCTAssertTrue(archives.isEmpty, "a queued draft is not an archive the queue reports")

        clock.advance(60)
        // The accept's own drain may still be running, and it found nothing due; drain until the row lands.
        for _ in 0..<50 where settled.succeeded == 0 {
            await writes.drain(userId: "")
            try await Task.sleep(for: .milliseconds(20))
        }
        let drafts = scripted.calls.filter { $0.path == "drafts" }
        XCTAssertEqual(drafts.count, 2)
        let raws = drafts.map { call -> String? in
            let json = (try? JSONSerialization.jsonObject(with: Data(call.body.utf8))) as? [String: Any]
            return (json?["message"] as? [String: Any])?["raw"] as? String
        }
        XCTAssertNotNil(raws[0])
        XCTAssertEqual(raws[0], raws[1], "the retry replays the message that was built")
        XCTAssertTrue(drafts[1].body.contains(#""threadId":"T1""#))
        XCTAssertFalse(posts(scripted).contains("threads/T1/modify"), "a retried draft never files the thread")
        XCTAssertEqual(settled.succeeded, 1)
    }

    func testADeferredDraftThatIsThrottledIsQueuedWithoutTellingAnyone() async throws {
        gmail { $0.path == "drafts" ? (429, "application/json", "{}") : nil }
        let result = await run("create_draft", ["to": "dana@acme.co", "subject": "Hi", "body": "x"], defer: true)
        XCTAssertEqual(result.text, "Draft to dana@acme.co saved in \(owner).")
        XCTAssertTrue(result.deferred)
        for _ in 0..<100 where try await queuedDrafts() == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        let rows = try await queuedDrafts()
        XCTAssertEqual(rows, 1)
        XCTAssertEqual(notices.appending(to: "", conversation: "call"), "", "the receipt already said it was saved, and it will be")
    }

    // MARK: - Helpers

    private func notice() async throws -> String {
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(20))
            let told = notices.appending(to: "", conversation: "call")
            if !told.isEmpty { return told }
        }
        XCTFail("the deferred write's failure never reached the notice channel")
        return ""
    }

    private func queuedDrafts() async throws -> Int {
        try await writePool.read { db in
            try PendingMailWrite.filter(Column("operation") == "create_draft" && Column("state") == "pending").fetchCount(db)
        }
    }
}

// MARK: - Harness

private final class ComposeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false
    func first() -> Bool { lock.lock(); defer { used = true; lock.unlock() }; return !used }
}

private final class ComposeSettled: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var succeeded: Int { lock.lock(); defer { lock.unlock() }; return count }
    func add(_ job: PendingMailWrite, _ outcome: PendingMailWrites.Outcome) {
        guard case .succeeded = outcome else { return }
        lock.lock(); count += 1; lock.unlock()
    }
}

private final class ComposeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date()
    var now: Date { lock.lock(); defer { lock.unlock() }; return current }
    func advance(_ seconds: TimeInterval) { lock.lock(); current += seconds; lock.unlock() }
}

private final class ComposeTokenProvider: GoogleTokenProvider {

    func token(for email: String?, requiredScopes: [String]) async -> Result<GoogleCredential.Token, GoogleCredential.Failure> {
        guard let email else { return .failure(.noStoredGrant) }
        return .success(.init(accessToken: "access-\(email)", email: email, scopes: requiredScopes))
    }
}

private final class ComposeGrantStorage: GoogleGrantStorage, @unchecked Sendable {
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
