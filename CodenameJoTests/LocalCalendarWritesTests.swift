// coverage-target: CodenameJo/Services/BackgroundRefresh/LocalCalendarWrites.swift

import FactoryKit
import Foundation
import GRDB
import XCTest

@testable import CodenameJo

/// Answering and cancelling invitations on the phone's own Calendar grant: the PATCH that changes only the
/// user's answer, every refusal that is decided by the event read, the receipts `CalendarRSVPQueuePolicy`
/// reads, and the cache once a deferred write lands. Google and the grant are stubbed at the container.
@MainActor
final class LocalCalendarWritesTests: XCTestCase {
    private let owner = "owner@example.test"
    private var directory: URL!

    override func setUp() async throws {
        try await super.setUp()
        let grants = CalendarGrantStorage()
        grants.store(GoogleAccountStore.Grant(email: owner, refreshToken: "refresh", scopes: [
            "https://www.googleapis.com/auth/calendar.readonly", "https://www.googleapis.com/auth/calendar.events",
        ], grantedAt: Date(), isPrimary: true))
        Container.shared.googleGrantStorage.register { grants }
        Container.shared.googleTokenProvider.register { MainActor.assumeIsolated { CalendarTokenProvider() } }
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("context.sqlite")
        Container.shared.localContext.register { LocalContextStore(url: url) }
    }

    override func tearDown() async throws {
        Container.shared.googleGrantStorage.reset()
        Container.shared.googleTokenProvider.reset()
        Container.shared.providerHTTP.reset()
        Container.shared.localContext.reset()
        Container.shared.localWriteNotices.reset()
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    /// A calendar holding one event, answering its read and every write with `write`'s status.
    @discardableResult
    private func calendar(_ event: [String: Any], write: Int = 200, read: Int = 200) -> ScriptedGmail {
        let body = String(decoding: try! JSONSerialization.data(withJSONObject: event), as: UTF8.self)
        let scripted = ScriptedGmail { call in
            guard call.path.hasPrefix("/calendar/v3/calendars/primary/events/") else { return (404, "application/json", "{}") }
            if call.method == "GET" { return read == 200 ? (200, "application/json", body) : (read, "application/json", "{}") }
            return (write, "application/json", write == 200 ? body : "{}")
        }
        Container.shared.providerHTTP.register { scripted }
        return scripted
    }

    private func invitation(id: String = "e1", me: String = "needsAction", organizer: Bool = false,
                            invited: Bool = true) -> [String: Any] {
        var attendees: [[String: Any]] = [
            ["email": "boss@example.test", "organizer": true, "responseStatus": "accepted"],
            ["email": "peer@example.test", "responseStatus": "tentative", "comment": "maybe"],
        ]
        if invited { attendees.insert(["email": owner, "self": true, "responseStatus": me], at: 1) }
        return ["id": id, "summary": "Planning", "status": "confirmed", "attendees": attendees,
                "start": ["dateTime": "2026-10-12T10:00:00-07:00"], "organizer": ["self": organizer]]
    }

    private func run(_ name: String, _ args: [String: Any], defer deferred: Bool = false) async -> FullDuplexBroker.ToolResult {
        let data = try! JSONSerialization.data(withJSONObject: args)
        return await LocalCalendarWrites.run(name: name, argumentsJSON: String(decoding: data, as: UTF8.self),
                                             defer: deferred, conversationId: "call")
    }

    private func writes(_ scripted: ScriptedGmail) -> [ScriptedGmail.Call] {
        scripted.calls.filter { $0.method != "GET" }
    }

    // MARK: - respond_to_calendar_event

    func testAnRSVPPatchesTheWholeListWithOnlyTheUsersAnswerChanged() async throws {
        let scripted = calendar(invitation())
        let result = await run("respond_to_calendar_event", ["event_id": "e1", "response": "declined"])
        XCTAssertEqual(result.text, "Declined \"Planning\" (2026-10-12T10:00:00-07:00) as \(owner). The organizer was notified.")
        XCTAssertEqual(result.ok, true)
        let patch = try XCTUnwrap(writes(scripted).first)
        XCTAssertEqual(patch.method, "PATCH")
        XCTAssertEqual(patch.query["sendUpdates"], "all")
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(patch.body.utf8)) as? [String: Any])
        let attendees = try XCTUnwrap(sent["attendees"] as? [[String: Any]])
        let original = invitation()["attendees"] as! [[String: Any]]
        XCTAssertEqual(attendees.count, original.count)
        for (after, before) in zip(attendees, original) {
            let isMe = before["self"] as? Bool == true
            XCTAssertEqual(after["responseStatus"] as? String, isMe ? "declined" : before["responseStatus"] as? String)
            XCTAssertEqual(after["email"] as? String, before["email"] as? String)
            XCTAssertEqual(after["comment"] as? String, before["comment"] as? String)
        }
        XCTAssertEqual(Set(sent.keys), ["attendees"])
    }

    func testTheSameAnswerTwiceChangesNothingAndNotifiesNobody() async {
        let scripted = calendar(invitation(me: "accepted"))
        let result = await run("respond_to_calendar_event", ["event_id": "e1", "response": "accepted"])
        XCTAssertEqual(result.text, "\"Planning\" (2026-10-12T10:00:00-07:00) was already accepted on \(owner). "
            + "Nothing changed and nobody was notified again.")
        XCTAssertEqual(result.ok, true)
        XCTAssertTrue(writes(scripted).isEmpty)
    }

    func testAnEventWithoutTheUserAsAttendeeHasNothingToAnswer() async {
        let organized = calendar(invitation(organizer: true, invited: false))
        let own = await run("respond_to_calendar_event", ["event_id": "e1", "response": "accepted"])
        XCTAssertEqual(own.text, "\"Planning\" is an event \(owner) created, so there is nothing to accept or decline. "
            + "Deleting or cancelling it isn't something you can do.")
        XCTAssertEqual(own.ok, false)
        XCTAssertTrue(writes(organized).isEmpty)

        calendar(invitation(invited: false))
        let elsewhere = await run("respond_to_calendar_event", ["event_id": "e1", "response": "accepted"])
        XCTAssertEqual(elsewhere.text, "\(owner) isn't on the invitation for \"Planning\", so there is no response to give. "
            + "It may be on another connected calendar.")
    }

    func testOneOccurrenceSaysItWasNotTheSeriesAndTentativeReadsAsAVerb() async {
        calendar(invitation(id: "base_20261012T170000Z"))
        let result = await run("respond_to_calendar_event", ["event_id": "base_20261012T170000Z", "response": "tentative"])
        XCTAssertEqual(result.text, "Tentatively accepted \"Planning\" (2026-10-12T10:00:00-07:00) as \(owner). "
            + "The organizer was notified. This was that one occurrence, not the whole recurring series.")
    }

    func testMissingArgumentsAreRefusedBeforeGoogle() async {
        let scripted = calendar(invitation())
        let noId = await run("respond_to_calendar_event", ["response": "accepted"])
        XCTAssertEqual(noId.text, "No event id — search or list the calendar first, then answer one of the results.")
        let badAnswer = await run("respond_to_calendar_event", ["event_id": "e1", "response": "maybe"])
        XCTAssertEqual(badAnswer.text, "\"maybe\" isn't an answer. Pass response as \"accepted\", \"declined\" or \"tentative\".")
        let noCancel = await run("cancel_calendar_event", [:])
        XCTAssertEqual(noCancel.text, "No event id — search or list the calendar first, then cancel one of the results.")
        XCTAssertTrue(scripted.calls.isEmpty)
    }

    // MARK: - cancel_calendar_event

    func testCancellingSaysWhoWasToldDependingOnWhoOrganizedIt() async {
        let mine = calendar(invitation(organizer: true))
        let cancelled = await run("cancel_calendar_event", ["event_id": "e1"])
        XCTAssertEqual(cancelled.text, "Cancelled \"Planning\" (2026-10-12T10:00:00-07:00) on \(owner). "
            + "The 2 guests were emailed a cancellation.")
        XCTAssertEqual(writes(mine).map(\.method), ["DELETE"])
        XCTAssertEqual(writes(mine).first?.query["sendUpdates"], "all")

        var solo = invitation(organizer: true)
        solo["attendees"] = [["email": owner, "self": true], ["email": "one@example.test"]]
        calendar(solo)
        let one = await run("cancel_calendar_event", ["event_id": "e1"])
        XCTAssertTrue(one.text.hasSuffix(" The guest was emailed a cancellation."), one.text)

        calendar(invitation(id: "base_20261012", organizer: false))
        let theirs = await run("cancel_calendar_event", ["event_id": "base_20261012"])
        XCTAssertEqual(theirs.text, "Took \"Planning\" (2026-10-12T10:00:00-07:00) off \(owner)'s calendar. The user didn't "
            + "organize it, so it is still on everyone else's and nobody was told why — declining it is what tells the "
            + "organizer. That was the one occurrence, not the whole recurring series.")
        XCTAssertEqual(theirs.ok, true)
    }

    func testAnAlreadyCancelledEventIsLeftAlone() async {
        var gone = invitation(organizer: true)
        gone["status"] = "cancelled"
        let scripted = calendar(gone)
        let result = await run("cancel_calendar_event", ["event_id": "e1"])
        XCTAssertEqual(result.text, "\"Planning\" was already cancelled. Nothing to do, and nobody was notified again.")
        XCTAssertEqual(result.ok, false)
        XCTAssertTrue(writes(scripted).isEmpty)
    }

    // MARK: - Failures

    func testAMissingEventAndAStaleGrantSayWhatToDo() async {
        calendar(invitation(), read: 404)
        let missing = await run("cancel_calendar_event", ["event_id": "e1"])
        XCTAssertEqual(missing.text, "NOT CANCELLED — that event id doesn't resolve on \(owner)'s calendar. List the "
            + "calendar again and use an id from those results. Tell the user you couldn't find the event; never say you cancelled it.")
        XCTAssertEqual(missing.ok, false)

        calendar(invitation(), read: 403)
        let stale = await run("respond_to_calendar_event", ["event_id": "e1", "response": "accepted"])
        XCTAssertEqual(stale.text, "\(owner) needs reconnecting before it can answer invitations — its access predates "
            + "that permission. Remove and re-add the account in Settings, then try again.")

        calendar(invitation(), write: 404)
        let lost = await run("respond_to_calendar_event", ["event_id": "e1", "response": "accepted"])
        XCTAssertTrue(lost.text.hasPrefix("NOT ANSWERED — that event id doesn't resolve"), lost.text)
    }

    func testADeferredWriteAnswersFirstAndTellsTheConversationWhenItFails() async throws {
        let notices = LocalWriteNotices()
        Container.shared.localWriteNotices.register { notices }
        calendar(invitation(organizer: true), write: 404)
        let result = await run("cancel_calendar_event", ["event_id": "e1"], defer: true)
        XCTAssertTrue(result.deferred)
        XCTAssertEqual(result.ok, true)
        XCTAssertTrue(result.text.hasPrefix("Cancelled \"Planning\""))
        let told = try await firstNotice(notices)
        XCTAssertEqual(told, "\n\nthat didn't go through — the event id doesn't resolve on \(owner)'s calendar, so the "
            + "event is still on the calendar and nobody was told. List the calendar again and act on an id from those results.")
        XCTAssertEqual(LocalCalendarWrites.deferredFailure(CalendarAPI.Failure.unauthorized, target: owner,
            capability: "answer invitations", unchanged: "your answer wasn't sent and the organizer wasn't told"),
            "that didn't go through — \(owner) needs reconnecting before it can answer invitations, so your answer wasn't "
                + "sent and the organizer wasn't told. Remove and re-add the account in Settings, then try again.")
    }

    func testADeferredWriteUpdatesTheCacheOnceItLands() async throws {
        let store = CalendarStore(database: Container.shared.localContext().dbPool)
        await store.cache(events: [cached("e1"), cached("e2")], attendees: [])
        calendar(invitation())
        let answered = await run("respond_to_calendar_event", ["event_id": "e1", "response": "accepted"], defer: true)
        XCTAssertTrue(answered.deferred)
        calendar(invitation(id: "e2", organizer: true))
        _ = await run("cancel_calendar_event", ["event_id": "e2"], defer: true)
        for _ in 0..<100 {
            let response = await store.search(account: owner, timeMinMs: 0, timeMaxMs: 10_000)
            if response.events.map(\.id) == ["e1"],
               response.attendees.first(where: { $0.email == owner })?.responseStatus == "accepted" { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("the deferred RSVP and cancel never reached the calendar cache")
    }

    private func firstNotice(_ notices: LocalWriteNotices) async throws -> String {
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(20))
            let told = notices.appending(to: "", conversation: "call")
            if !told.isEmpty { return told }
        }
        XCTFail("no notice arrived")
        return ""
    }

    private func cached(_ id: String) -> CalendarStore.Event {
        CalendarStore.Event(id: id, calendarId: "primary", account: owner, summary: "Planning", location: nil,
            description: nil, startRaw: nil, endRaw: nil, startEpochMs: 1_000, endEpochMs: 2_000, isAllDay: false,
            status: "confirmed", recurringEventId: nil, htmlLink: nil, attendeeCount: 3, cachedAt: Date())
    }
}

private final class CalendarTokenProvider: GoogleTokenProvider {

    func token(for email: String?, requiredScopes: [String]) async -> Result<GoogleCredential.Token, GoogleCredential.Failure> {
        guard let email else { return .failure(.noStoredGrant) }
        return .success(.init(accessToken: "access-\(email)", email: email, scopes: requiredScopes))
    }
}

private final class CalendarGrantStorage: GoogleGrantStorage, @unchecked Sendable {
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
