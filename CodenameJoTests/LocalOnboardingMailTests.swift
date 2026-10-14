// coverage-target: CodenameJo/Services/BackgroundRefresh/LocalOnboardingMail.swift

import FactoryKit
import Foundation
import XCTest

@testable import CodenameJo

/// Onboarding's mail, picked on the phone.
///
/// This is the only selection the user ever hears walked out loud, and it is picked under a
/// rate limit shared with the broker, so the parts worth holding are the ones a demo would
/// not show: the picks are **per mailbox with that mailbox's own token**, the **welcome
/// thread is not offered twice**, a step's **count is clamped** rather than trusted, a
/// **failed lookup is said out loud** instead of rendering as a quiet empty queue, and the
/// **cleanup offer only appears above the threshold** that makes it worth asking about.
///
/// Every boundary is stubbed at the container — `googleGrantStorage`, `googleTokenProvider`
/// and `providerHTTP`. Nothing here reaches the Keychain or the network, and the `MailStore`
/// is the degraded no-database one, so every message comes from the scripted Gmail rather
/// than from a cache.
@MainActor
final class LocalOnboardingMailTests: XCTestCase {

    private static let importantQuery = "in:inbox is:important newer_than:7d"
    private static let promotionsQuery = "in:inbox category:promotions"

    private var grants: OnboardingGrantStorage!
    private var tokens: OnboardingTokenProvider!
    private var script: GmailScript!
    private var gmail: ScriptedGmail!
    private var store: MailStore!

    override func setUp() async throws {
        try await super.setUp()
        grants = OnboardingGrantStorage()
        tokens = OnboardingTokenProvider()
        script = GmailScript()
        store = MailStore(database: nil, userId: "onboarding-tests")
        let grants = grants!
        let tokens = tokens!
        Container.shared.googleGrantStorage.register { grants }
        Container.shared.googleTokenProvider.register { MainActor.assumeIsolated { tokens } }
    }

    override func tearDown() async throws {
        Container.shared.googleGrantStorage.reset()
        Container.shared.googleTokenProvider.reset()
        Container.shared.providerHTTP.reset()
        grants = nil
        tokens = nil
        script = nil
        gmail = nil
        store = nil
        try await super.tearDown()
    }

    // MARK: - Harness

    @discardableResult
    private func connect(_ email: String) -> String {
        grants.store(
            GoogleAccountStore.Grant(
                email: email, refreshToken: "refresh", scopes: [],
                grantedAt: Date(timeIntervalSince1970: 1_700_000_000), isPrimary: grants.all().isEmpty))
        let token = "access-\(email)"
        tokens.tokens[email] = token
        return token
    }

    /// Wire the scripted Gmail up. Called once a test has finished describing the mailbox.
    private func serve() {
        let script = script!
        gmail = ScriptedGmail { call in
            if call.path.contains("batch") { return (200, GmailScript.batchContentType, script.batch(call.body)) }
            let query = call.query["q"] ?? ""
            return script.page(token: call.bearerToken, query: query)
        }
        let gmail = gmail!
        Container.shared.providerHTTP.register { gmail }
    }

    private func flow(config: EmailOnboardingConfig? = nil, welcome: EmailOnboardingItem? = nil)
        -> EmailOnboardingFlow {
        EmailOnboardingFlow(version: config == nil ? 1 : 2, runId: "run-1", welcome: welcome, config: config)
    }

    private func prepare(
        config: EmailOnboardingConfig? = nil, welcome: EmailOnboardingItem? = nil
    ) async -> EmailOnboardingSelection {
        serve()
        return await LocalOnboardingMail.prepare(flow: flow(config: config, welcome: welcome), store: store)
    }

    private func step(_ kind: String, query: String? = nil, count: Int? = nil) -> EmailOnboardingConfig.Step {
        .init(id: kind, kind: kind, line: nil, question: nil, query: query, count: count,
              note: nil, say: nil, then: nil, tip: nil)
    }

    // MARK: - No grant

    /// Sign-in can finish without a Google consent, and onboarding still runs. The honest
    /// answer is an empty selection *with* a sentence — a silent empty one reads to the user
    /// as "you have no mail" rather than as "I could not look".
    func testAPhoneWithNoGoogleGrantSaysSoRatherThanReturningAQuietlyEmptyQueue() async {
        let selection = await prepare()

        XCTAssertTrue(selection.items.isEmpty)
        XCTAssertEqual(selection.failures, ["The remaining onboarding emails could not be loaded."])
        XCTAssertTrue(gmail.calls.isEmpty, "no grant means no Gmail request at all")
    }

    // MARK: - The important picks

    /// Two of them, newest first, numbered as steps 2 and 3 — v1's fixed shape.
    func testTheTwoNewestImportantThreadsBecomeStepsTwoAndThree() async {
        let token = connect("sam@example.com")
        script.list(token: token, query: Self.importantQuery, ["old", "newest", "middle"])
        script.message("old", internalDate: 1_000)
        script.message("middle", internalDate: 2_000)
        script.message("newest", internalDate: 3_000)

        let selection = await prepare()

        XCTAssertEqual(selection.items.map(\.id), ["newest", "middle"])
        XCTAssertEqual(selection.items.map(\.onboardingStep), [2, 3])
        XCTAssertTrue(selection.failures.isEmpty)
    }

    /// The welcome mail is step 1 and is already in the queue. Offering it again as an
    /// "important" pick would walk the user through the same thread twice.
    func testTheWelcomeThreadIsNotOfferedAgainAsAnImportantPick() async {
        let token = connect("sam@example.com")
        script.list(token: token, query: Self.importantQuery, ["welcome", "second", "third"])
        script.message("welcome", internalDate: 3_000)
        script.message("second", internalDate: 2_000)
        script.message("third", internalDate: 1_000)
        let welcome = EmailOnboardingItem(
            account: "sam@example.com", id: "welcome", threadId: "welcome-thread", from: "Jo",
            subject: "Welcome", date: "", snippet: "", internalDate: 3_000, onboardingStep: 1,
            cleanup: nil)

        let selection = await prepare(welcome: welcome)

        XCTAssertEqual(selection.items.map(\.id), ["second", "third"])
    }

    /// A thread listed twice — the same conversation matching two of an operator's queries —
    /// is one stop, not two.
    func testAThreadMatchingTwoStepsIsOfferedOnlyOnce() async {
        let token = connect("sam@example.com")
        let config = EmailOnboardingConfig(
            opening: nil,
            steps: [step("welcome"), step("important", query: "first", count: 1),
                    step("important", query: "second", count: 1)])
        script.list(token: token, query: "first", ["shared", "only-here"])
        script.list(token: token, query: "second", ["shared"])
        script.message("shared", internalDate: 3_000)
        script.message("only-here", internalDate: 1_000)

        let selection = await prepare(config: config)

        XCTAssertEqual(selection.items.map(\.id), ["shared"], "the second step has nothing left to offer")
    }

    /// What the queue reads out comes from the headers, and the date is the ISO form of
    /// Gmail's millisecond clock rather than the raw number.
    func testAnItemCarriesTheHeadersAndAnIsoDateFromGmailsMillisecondClock() async {
        let token = connect("sam@example.com")
        script.list(token: token, query: Self.importantQuery, ["m1"])
        script.message(
            "m1", internalDate: 1_700_000_000_000, from: "Sarah Chen <sarah@acme.test>",
            subject: "Contract", snippet: "Can you sign")

        let selection = await prepare()

        let item = try? XCTUnwrap(selection.items.first)
        XCTAssertEqual(item?.from, "Sarah Chen <sarah@acme.test>")
        XCTAssertEqual(item?.subject, "Contract")
        XCTAssertEqual(item?.snippet, "Can you sign")
        XCTAssertEqual(item?.internalDate, 1_700_000_000_000)
        XCTAssertEqual(
            item?.date,
            ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 1_700_000_000)))
    }

    /// Mail with no `From` or `Subject` exists. It must still become a stop that says what it
    /// is missing, rather than an item with two empty strings in it.
    func testAMessageWithNoSenderOrSubjectStillBecomesAReadableStop() async {
        let token = connect("sam@example.com")
        script.list(token: token, query: Self.importantQuery, ["bare"])
        script.message("bare", internalDate: 1_000, from: nil, subject: nil, snippet: nil)

        let selection = await prepare()

        XCTAssertEqual(selection.items.first?.from, "unknown sender")
        XCTAssertEqual(selection.items.first?.subject, "(no subject)")
        XCTAssertEqual(selection.items.first?.snippet, "")
    }

    // MARK: - Two mailboxes

    /// Each mailbox is listed with its own token, and both can contribute to the picks.
    /// Listing one account's mail with another's grant is the failure this guards.
    func testEachMailboxIsListedWithItsOwnTokenAndBothContribute() async {
        let sam = connect("sam@example.com")
        let dana = connect("dana@example.com")
        script.list(token: sam, query: Self.importantQuery, ["sam-1"])
        script.list(token: dana, query: Self.importantQuery, ["dana-1"])
        script.message("sam-1", internalDate: 2_000)
        script.message("dana-1", internalDate: 1_000)

        let selection = await prepare()

        XCTAssertEqual(selection.items.map(\.id), ["sam-1", "dana-1"], "newest first across mailboxes")
        XCTAssertEqual(
            selection.items.map(\.account), ["sam@example.com", "dana@example.com"],
            "each item names the mailbox it came out of")
        let searches = gmail.calls.filter { $0.query["q"] == Self.importantQuery }
        XCTAssertEqual(Set(searches.map(\.bearerToken)), [sam, dana])
    }

    // MARK: - Failures

    /// A refused list is a sentence the user hears, not a shorter queue (PRINCIPLES 18).
    func testARefusedImportantLookupIsReportedRatherThanSwallowed() async {
        let token = connect("sam@example.com")
        script.status(token: token, query: Self.importantQuery, 500)

        let selection = await prepare()

        XCTAssertTrue(selection.items.isEmpty)
        XCTAssertEqual(selection.failures, ["Recent important emails could not be loaded."])
    }

    /// Two mailboxes failing the same way is one thing to say, not two.
    func testTheSameFailureAcrossTwoMailboxesIsSaidOnce() async {
        let sam = connect("sam@example.com")
        let dana = connect("dana@example.com")
        script.status(token: sam, query: Self.importantQuery, 500)
        script.status(token: dana, query: Self.importantQuery, 500)

        let selection = await prepare()

        XCTAssertEqual(selection.failures, ["Recent important emails could not be loaded."])
    }

    /// One mailbox failing must not cost the other its picks.
    func testAFailureInOneMailboxStillLeavesTheOthersPicks() async {
        let sam = connect("sam@example.com")
        let dana = connect("dana@example.com")
        script.status(token: sam, query: Self.importantQuery, 500)
        script.list(token: dana, query: Self.importantQuery, ["dana-1"])
        script.message("dana-1", internalDate: 1_000)

        let selection = await prepare()

        XCTAssertEqual(selection.items.map(\.id), ["dana-1"])
        XCTAssertEqual(selection.failures.count, 1)
    }

    // MARK: - The operator's steps

    /// v2 runs whatever the broker's config names: its query, and its position as the step
    /// number — not v1's fixed 2, 3 and 4.
    func testV2TakesItsQueryAndItsStepNumberFromTheConfig() async {
        let token = connect("sam@example.com")
        let config = EmailOnboardingConfig(
            opening: nil,
            steps: [step("welcome"), step("beat"), step("important", query: "label:vip", count: 1)])
        script.list(token: token, query: "label:vip", ["vip-1"])
        script.message("vip-1", internalDate: 1_000)

        let selection = await prepare(config: config)

        XCTAssertEqual(selection.items.map(\.id), ["vip-1"])
        XCTAssertEqual(selection.items.first?.onboardingStep, 3, "the third step in the config")
        XCTAssertEqual(gmail.calls.first?.query["q"], "label:vip")
    }

    /// An operator asking for nine emails gets three. Onboarding is a walk, not an inbox,
    /// and the cap is the thing that keeps it one.
    func testAStepAskingForMoreThanThreeImportantEmailsIsCappedAtThree() async {
        let token = connect("sam@example.com")
        let config = EmailOnboardingConfig(
            opening: nil, steps: [step("important", query: "anything", count: 9)])
        script.list(token: token, query: "anything", ["a", "b", "c", "d", "e"])
        for (index, id) in ["a", "b", "c", "d", "e"].enumerated() {
            script.message(id, internalDate: Int64(10 - index) * 1_000)
        }

        let selection = await prepare(config: config)

        XCTAssertEqual(selection.items.map(\.id), ["a", "b", "c"])
    }

    /// And one asking for none gets one, because a step with nothing in it is a stop the
    /// assistant would announce and then have nothing to say about.
    func testAStepAskingForNoImportantEmailsStillGetsOne() async {
        let token = connect("sam@example.com")
        let config = EmailOnboardingConfig(
            opening: nil, steps: [step("important", query: "anything", count: 0)])
        script.list(token: token, query: "anything", ["a", "b"])
        script.message("a", internalDate: 2_000)
        script.message("b", internalDate: 1_000)

        let selection = await prepare(config: config)

        XCTAssertEqual(selection.items.map(\.id), ["a"])
    }

    // MARK: - The cleanup offer

    /// Above the threshold the promotional sender becomes an offer carrying the count, the
    /// name the assistant will say, and the exact query the dispatch may widen to — and no
    /// further.
    func testAPromotionalSenderWithEnoughInboxMailBecomesACleanupOffer() async {
        let token = connect("sam@example.com")
        script.list(token: token, query: Self.importantQuery, [])
        script.list(token: token, query: Self.promotionsQuery, ["promo-1"])
        script.message("promo-1", internalDate: 5_000, from: "Shop Weekly <deals@shop.test>")
        script.list(
            token: token, query: "in:inbox category:promotions from:deals@shop.test",
            ["p1", "p2", "p3", "p4", "p5"])

        let selection = await prepare()

        let cleanup = try? XCTUnwrap(selection.items.first?.cleanup)
        XCTAssertEqual(selection.items.first?.onboardingStep, 4)
        XCTAssertEqual(cleanup?.senderInboxCount, 5)
        XCTAssertEqual(cleanup?.atLeast, false)
        XCTAssertEqual(cleanup?.senderDisplayName, "Shop Weekly")
        XCTAssertEqual(cleanup?.query, "in:inbox category:promotions from:deals@shop.test")
        XCTAssertEqual(cleanup?.account, "sam@example.com")
    }

    /// Four is below the threshold, so there is nothing worth offering to batch — and the
    /// step is dropped rather than offered with a count that makes the offer look silly.
    func testAPromotionalSenderBelowTheThresholdIsNotOfferedAtAll() async {
        let token = connect("sam@example.com")
        script.list(token: token, query: Self.importantQuery, [])
        script.list(token: token, query: Self.promotionsQuery, ["promo-1"])
        script.message("promo-1", internalDate: 5_000, from: "Shop Weekly <deals@shop.test>")
        script.list(
            token: token, query: "in:inbox category:promotions from:deals@shop.test",
            ["p1", "p2", "p3", "p4"])

        let selection = await prepare()

        XCTAssertTrue(selection.items.isEmpty, "four is not a pile worth offering to clear")
        XCTAssertTrue(selection.failures.isEmpty, "and it is not a failure either")
    }

    /// A count page with a cursor means Gmail stopped counting, not that the pile ends
    /// there — the assistant has to say "at least".
    func testACountPageWithMoreToComeIsOfferedAsAtLeast() async {
        let token = connect("sam@example.com")
        script.list(token: token, query: Self.importantQuery, [])
        script.list(token: token, query: Self.promotionsQuery, ["promo-1"])
        script.message("promo-1", internalDate: 5_000, from: "Shop Weekly <deals@shop.test>")
        script.list(
            token: token, query: "in:inbox category:promotions from:deals@shop.test",
            ["p1", "p2", "p3", "p4", "p5"], next: "page-2")

        let selection = await prepare()

        XCTAssertEqual(selection.items.first?.cleanup?.atLeast, true)
        XCTAssertEqual(selection.items.first?.cleanup?.senderInboxCount, 5)
    }

    /// One offer per run, however many senders qualify. Onboarding has one cleanup step.
    func testOnlyOneCleanupOfferIsMadeEvenWhenTwoSendersQualify() async {
        let token = connect("sam@example.com")
        script.list(token: token, query: Self.importantQuery, [])
        script.list(token: token, query: Self.promotionsQuery, ["promo-1", "promo-2"])
        script.message("promo-1", internalDate: 5_000, from: "Shop Weekly <deals@shop.test>")
        script.message("promo-2", internalDate: 4_000, from: "Gallery <news@gallery.test>")
        for sender in ["deals@shop.test", "news@gallery.test"] {
            script.list(
                token: token, query: "in:inbox category:promotions from:\(sender)",
                ["a", "b", "c", "d", "e", "f"])
        }

        let selection = await prepare()

        XCTAssertEqual(selection.items.count, 1)
        XCTAssertEqual(selection.items.first?.cleanup?.senderDisplayName, "Shop Weekly")
    }

    /// The dispatched task is what actually archives mail, so it has to name the mailbox and
    /// the sender query exactly — a widened one would clear somebody's whole Promotions tab.
    func testTheCleanupDispatchNamesTheMailboxAndTheExactSenderQuery() async {
        let token = connect("sam@example.com")
        script.list(token: token, query: Self.importantQuery, [])
        script.list(token: token, query: Self.promotionsQuery, ["promo-1"])
        script.message("promo-1", internalDate: 5_000, from: "Shop Weekly <deals@shop.test>")
        script.list(
            token: token, query: "in:inbox category:promotions from:deals@shop.test",
            ["p1", "p2", "p3", "p4", "p5"])

        let selection = await prepare()

        let dispatch = try? XCTUnwrap(selection.items.first?.cleanup?.dispatch)
        XCTAssertEqual(dispatch?.account, "sam@example.com")
        XCTAssertEqual(dispatch?.expects, "receipt")
        XCTAssertEqual(
            dispatch?.task.contains("in:inbox category:promotions from:deals@shop.test"), true)
    }

    // MARK: - About senders

    /// Who writes most, ranked. Only the sender and a count leave the phone, which is why
    /// this is picked here rather than asked of the broker.
    func testAboutSendersAreRankedByHowOftenTheyWrite() async {
        let token = connect("sam@example.com")
        script.listMatching(token: token, containing: "-category:", ["a1", "a2", "b1"])
        script.message("a1", from: "Amy <amy@acme.test>")
        script.message("a2", from: "Amy <amy@acme.test>")
        script.message("b1", from: "Ben <ben@acme.test>")
        serve()

        let senders = await LocalOnboardingMail.aboutSenders(store: store,
            scope: .init(profileId: "work", isDefault: false, emails: ["sam@example.com"]))

        XCTAssertEqual(senders.map(\.from), ["Amy <amy@acme.test>", "Ben <ben@acme.test>"])
        XCTAssertEqual(senders.map(\.count), [2, 1])
        XCTAssertEqual(senders.map(\.account), ["sam@example.com", "sam@example.com"])
    }

    func testAboutIgnoresMailboxesOutsideCapturedProfile() async {
        let work = connect("sam@example.com")
        let personal = connect("personal@example.com")
        script.listMatching(token: work, containing: "-category:", ["work"])
        script.listMatching(token: personal, containing: "-category:", ["personal"])
        script.message("work", from: "Work <work@acme.test>")
        script.message("personal", from: "Private <private@home.test>")
        serve()

        let senders = await LocalOnboardingMail.aboutSenders(store: store,
            scope: .init(profileId: "work", isDefault: false, emails: ["sam@example.com"]))

        XCTAssertEqual(senders.map(\.account), ["sam@example.com"])
        XCTAssertEqual(senders.map(\.from), ["Work <work@acme.test>"])
    }

    func testAboutDoesNotReadMailWithoutKnownMembership() async {
        connect("sam@example.com")
        serve()
        let senders = await LocalOnboardingMail.aboutSenders(store: store,
            scope: .init(profileId: "work", isDefault: false))
        XCTAssertTrue(senders.isEmpty)
        XCTAssertTrue(gmail.calls.isEmpty)
    }

    /// Mail the user sent to themselves is not somebody writing to them.
    func testTheUsersOwnAddressIsNeverOneOfTheirAboutSenders() async {
        let token = connect("sam@example.com")
        script.listMatching(token: token, containing: "-category:", ["self", "other"])
        script.message("self", from: "Sam <SAM@example.com>")
        script.message("other", from: "Ben <ben@acme.test>")
        serve()

        let senders = await LocalOnboardingMail.aboutSenders(store: store,
            scope: .init(profileId: "work", isDefault: false, emails: ["sam@example.com"]))

        XCTAssertEqual(senders.map(\.from), ["Ben <ben@acme.test>"])
    }

    /// And with no grant there is nothing to summarise and nothing to ask Gmail.
    func testAboutSendersAreEmptyWithNoGrantAndAskGmailNothing() async {
        serve()

        let senders = await LocalOnboardingMail.aboutSenders(store: store,
            scope: .init(profileId: "work", isDefault: false, emails: ["sam@example.com"]))

        XCTAssertTrue(senders.isEmpty)
        XCTAssertTrue(gmail.calls.isEmpty)
    }
}

// MARK: - Stubs

private final class OnboardingGrantStorage: GoogleGrantStorage, @unchecked Sendable {
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

private final class OnboardingTokenProvider: GoogleTokenProvider {
    var tokens: [String: String] = [:]


    func token(
        for email: String?, requiredScopes: [String]
    ) async -> Result<GoogleCredential.Token, GoogleCredential.Failure> {
        guard let email, let access = tokens[email] else { return .failure(.noStoredGrant) }
        return .success(.init(accessToken: access, email: email, scopes: requiredScopes))
    }
}

/// A scripted mailbox: which ids each search answers with, and the headers behind each id.
private final class GmailScript: @unchecked Sendable {
    static let batchContentType = "multipart/mixed; boundary=aurex_reply"

    private struct Page { let ids: [String]; let next: String? }
    private struct Message {
        let id: String
        let internalDate: Int64
        let from: String?
        let subject: String?
        let snippet: String?
    }

    private let lock = NSLock()
    private var pages: [String: Page] = [:]
    private var fuzzy: [(token: String, needle: String, page: Page)] = []
    private var statuses: [String: Int] = [:]
    private var messages: [String: Message] = [:]

    private func key(_ token: String, _ query: String) -> String { "\(token)|\(query)" }

    func list(token: String, query: String, _ ids: [String], next: String? = nil) {
        lock.lock()
        pages[key(token, query)] = Page(ids: ids, next: next)
        lock.unlock()
    }

    /// For the two "about you" searches, whose exact text is private to the production file.
    func listMatching(token: String, containing needle: String, _ ids: [String]) {
        lock.lock()
        fuzzy.append((token, needle, Page(ids: ids, next: nil)))
        lock.unlock()
    }

    func status(token: String, query: String, _ code: Int) {
        lock.lock()
        statuses[key(token, query)] = code
        lock.unlock()
    }

    func message(
        _ id: String, internalDate: Int64 = 1_000, from: String? = "Someone <someone@example.test>",
        subject: String? = "Subject", snippet: String? = "preview"
    ) {
        lock.lock()
        messages[id] = Message(
            id: id, internalDate: internalDate, from: from, subject: subject, snippet: snippet)
        lock.unlock()
    }

    /// `messages.list`, as the transport should answer it.
    func page(token: String, query: String) -> (Int, String, String) {
        lock.lock()
        defer { lock.unlock() }
        if let status = statuses[key(token, query)] { return (status, "application/json", "{}") }
        let page = pages[key(token, query)]
            ?? fuzzy.first { $0.token == token && query.contains($0.needle) }?.page
            ?? Page(ids: [], next: nil)
        let refs = page.ids.map { #"{"id":"\#($0)","threadId":"\#($0)-thread"}"# }.joined(separator: ",")
        let cursor = page.next.map { #","nextPageToken":"\#($0)""# } ?? ""
        return (200, "application/json", #"{"messages":[\#(refs)]\#(cursor)}"#)
    }

    /// `messages.get` for every id named in a `multipart/mixed` batch body.
    func batch(_ body: String) -> String {
        var parts = ""
        for id in Self.ids(inBatch: body) {
            lock.lock()
            let message = messages[id]
            lock.unlock()
            guard let message else { continue }
            parts += "--aurex_reply\r\nContent-Type: application/http\r\n\r\n"
            parts += "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n"
            parts += Self.json(message) + "\r\n\r\n"
        }
        return parts + "--aurex_reply--\r\n"
    }

    private static func ids(inBatch body: String) -> [String] {
        body.components(separatedBy: "/users/me/messages/").dropFirst().map {
            String($0.prefix { $0 != "?" && !$0.isWhitespace })
        }
    }

    private static func json(_ message: Message) -> String {
        var headers: [String] = []
        if let from = message.from { headers.append(#"{"name":"From","value":"\#(from)"}"#) }
        if let subject = message.subject {
            headers.append(#"{"name":"Subject","value":"\#(subject)"}"#)
        }
        let snippet = message.snippet.map { #""snippet":"\#($0)","# } ?? ""
        return #"""
            {"id":"\#(message.id)","threadId":"\#(message.id)-thread",\#(snippet)\#
            "labelIds":["INBOX"],"internalDate":"\#(message.internalDate)",\#
            "payload":{"headers":[\#(headers.joined(separator: ","))]}}
            """#
    }
}
