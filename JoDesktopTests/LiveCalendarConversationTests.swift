import XCTest
import FactoryKit
@testable import CodenameJo

final class LiveCalendarConversationTests: XCTestCase {
    func testInvitationMentionDoesNotAuthorizeCalendarAction() {
        for text in ["Reply that I sent the invite", "Reply back that I already sent the invite",
                     "Tell them I accepted the invitation", "Draft a note saying an invite will follow",
                     "Reply and send an invite. No, just email.", "Don't create an invite; reply only"] {
            XCTAssertFalse(CalendarConversationIntent.accepts(text), text)
        }
        for text in ["Reply and create the calendar invite", "Reply and send an invitation",
                     "Reply that 3–4 works and send an invite to both.",
                     "Send an invite and reply", "Just reply and create another invitation"] {
            XCTAssertTrue(CalendarConversationIntent.accepts(text), text)
        }
    }

    @MainActor func testProvisionalSpeechAndEmailCorrectionCannotLeavePhantomInvitationAfterRestart() async throws {
        Container.shared.manager.push()
        let previous = ProfileRuntime.snapshot; ProfileRuntime.install(nil)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let backend = BackendService(restoringSession: false); backend.userId = "calendar-correction"
        Container.shared.backend.register { backend }
        let jobs = DispatchJobStore(url: folder.appendingPathComponent("jobs.json"))
        Container.shared.dispatchJobs.register { jobs }
        defer { Scope.singleton.reset(); Container.shared.manager.pop(); ProfileRuntime.install(previous); try? FileManager.default.removeItem(at: folder) }
        let source = #"{"done":false,"item":{"id":"A","threadId":"thread-A","account":"owner@example.test","subject":"Phone call"}}"#
        let origin = try XCTUnwrap(DispatchJob.MailOrigin.captured(in: source))
        var event = CalendarActionReceipt(tool: CalendarTools.create, arguments: [:], account: origin.account,
            requestKey: "original-call", parentJobID: nil)
        let (priorEvent, _) = try await jobs.beginCalendarAction(event, ownerID: backend.userId!,
            profileID: nil, conversationID: nil, origin: origin)
        event.state = .confirmed; event.providerID = "original-event"
        _ = await jobs.recordCalendarAction(priorEvent.id, action: event, result: "Original phone call created")
        var calendar = LiveCalendarConversation()
        for (index, speech) in ["Yeah, you can reply back that I sent an invite for a", "For a phone call."].enumerated() {
            calendar.user(speech, selection: source, proposal: "", newTurn: true, jobs: jobs, finalized: false)
            XCTAssertNil(calendar.intent)
            calendar.user(speech, selection: source, proposal: "", newTurn: false, jobs: jobs)
            XCTAssertNil(calendar.intent, "Dictation segment \(index) must not create scheduling work")
        }
        calendar.user("Reply and send an invite", selection: source, proposal: "A phone call.", newTurn: true, jobs: jobs, finalized: false)
        XCTAssertNil(calendar.intent, "ASR prefixes cannot commit obligations")
        calendar.user("Reply and send an invite. No, just email.", selection: source, proposal: "", newTurn: false, jobs: jobs)
        XCTAssertNil(calendar.intent)
        XCTAssertNotNil(calendar.refusal(name: CalendarTools.create, arguments: "{}", now: checked, jobs: jobs))
        calendar.resolveWindow(for: "Just email that I sent the invite for next week.", newTurn: true, reference: checked, zone: zone)
        XCTAssertNil(calendar.window, "Email dictation must not require a new availability check")
        let availabilityReply = "Just reply with my availability next week."
        calendar.user(availabilityReply, selection: source, proposal: "", newTurn: true, jobs: jobs)
        calendar.resolveWindow(for: availabilityReply, newTurn: true, reference: checked, zone: zone)
        XCTAssertNotNil(calendar.window, "An email-only request can still require calendar evidence")
        XCTAssertNil(calendar.intent, "Reading availability is not authorization to create an invitation")

        var historical = CalendarConversationIntent(id: UUID(), source: origin, sourceState: source,
            request: "Yeah, you can reply back that I sent an invite", proposal: "")
        historical.followups = ["For a phone call.", "No, just email, just say that I already sent the invite."]
        historical.replyCall = "email-reply"
        let mail = MailActionReceipt(kind: .send, account: origin.account,
            message: .init(to: "receiver@example.test", subject: "Re: Phone call",
                body: "I already sent the invite.", threadId: origin.threadID),
            replyMessageID: origin.messageID, requestKey: "foreground:email-reply")
        let (reply, _) = try await jobs.beginMailAction(mail, ownerID: backend.userId!, profileID: nil,
            conversationID: nil, origin: origin)
        _ = await jobs.recordMailAction(reply.id, state: .sent, result: "Reply sent",
            provider: ["id": "sent-reply", "threadId": origin.threadID])
        _ = await jobs.saveCalendarIntent(historical, ownerID: backend.userId, profileID: nil)
        let restarted = DispatchJobStore(url: folder.appendingPathComponent("jobs.json"))
        XCTAssertNil(restarted.pendingCalendarIntent)
        let resolved = try XCTUnwrap(restarted.existing(historical.id))
        XCTAssertEqual(resolved.state, "done")
        XCTAssertEqual(resolved.calendarIntent?.inviteState, "not_requested")
        XCTAssertFalse(resolved.belongsInWorkQueue)
        let recovery = await restarted.recover()
        XCTAssertTrue(recovery.isEmpty)
        let history = await restarted.history()
        XCTAssertEqual(history.filter { $0.calendarAction != nil }.count, 1)
        XCTAssertEqual(history.filter { $0.mailAction?.state == .sent }.count, 1)

        calendar.scopeChanged()
        calendar.user("Actually schedule another call.", selection: source, proposal: "", newTurn: true, jobs: restarted)
        XCTAssertNil(calendar.refusal(name: CalendarTools.create, arguments: "{}", now: checked, jobs: restarted))
        XCTAssertNil(calendar.intent, "A new independent call must not inherit a completed invitation")
    }

    @MainActor func testCorrectionPreservesUnknownAndConfirmedReceiptsButNeverInventsReceiptLinkage() throws {
        let source = DispatchJob.MailOrigin(account: "owner@example.test", messageID: "A", threadID: "thread-A", sender: "", subject: "")
        for state in ["unknown", "confirmed", "pending"] {
            var intent = CalendarConversationIntent(id: UUID(), source: source, sourceState: "{}", request: "Reply and send an invite", proposal: "")
            intent.replyState = "confirmed"
            intent.inviteState = state
            intent.inviteCall = state == "pending" ? nil : "original-invite"
            intent.followups = ["No, just email"]
            intent.reconcile([])
            XCTAssertFalse(intent.needsInvitation)
            XCTAssertEqual(intent.inviteState, state == "pending" ? "not_requested" : state)
            XCTAssertEqual(intent.complete, state != "unknown")
            XCTAssertNotNil(intent.refusal(name: CalendarTools.create, arguments: "{}"))
            intent.replyCall = "original-reply"
            XCTAssertFalse(intent.refusal(name: "reply_email", arguments: "{}")?.contains("separate obligation") == true)
            intent.inviteCall = nil
            intent.withdrawInvitation()
            XCTAssertEqual(intent.inviteState, state == "pending" ? "not_requested" : state,
                           "Missing legacy call metadata must not erase a confirmed or uncertain state")
        }
        var genuine = CalendarConversationIntent(id: UUID(), source: source, sourceState: "{}",
            request: "Reply and create the calendar invite", proposal: "")
        var event = CalendarActionReceipt(tool: CalendarTools.create, arguments: [:], account: source.account,
            requestKey: "unrelated-old-event", parentJobID: nil)
        event.state = .confirmed
        genuine.reconcile([.init(id: UUID(), task: "Prior event", state: "done", origin: source, calendarAction: event)])
        XCTAssertEqual(genuine.inviteState, "pending", "Same-source events cannot satisfy a new invitation")
    }
    private let checked = ISO8601DateFormatter().date(from: "2026-11-03T20:00:00Z")!
    private let zone = TimeZone(identifier: "America/Los_Angeles")!
    private let arguments = #"{"time_min":"2026-11-09T00:00:00-08:00","time_max":"2026-11-10T00:00:00-08:00","time_zone":"America/Los_Angeles"}"#
    private let available = #"[{"account":"owner@example.test","complete":true,"availability":{"timeMin":"2026-11-09T00:00:00-08:00","timeMax":"2026-11-10T00:00:00-08:00","busy":[]}}]"#

    @MainActor func testNewCalendarReadRequiresNewSlotAssessmentBeforeSpeech() {
        var calendar = LiveCalendarConversation()
        calendar.recordRead(id: "first", arguments: arguments, output: available,
                            accounts: ["owner@example.test"], now: checked, zone: zone)
        let first = calendar.checkSlot(arguments: #"{"receipt_id":"first","start":"2026-11-09T13:00:00-08:00","end":"2026-11-09T14:00:00-08:00"}"#, now: checked)
        let second = calendar.checkSlot(arguments: #"{"receipt_id":"first","start":"2026-11-09T15:00:00-08:00","end":"2026-11-09T16:00:00-08:00"}"#, now: checked)
        XCTAssertEqual(first.status, "free")
        XCTAssertEqual(second.status, "free")
        let speech = calendar.presentation("You have a conflict.", user: "Check calendar availability", now: checked)
        XCTAssertNil(speech.failure)
        XCTAssertTrue(speech.text.contains("1:00 PM"))
        XCTAssertTrue(speech.text.contains("3:00 PM"))
        XCTAssertFalse(speech.text.contains("conflict"))

        calendar.recordRead(id: "refreshed", arguments: arguments, output: available,
                            accounts: ["owner@example.test"], now: checked, zone: zone)
        let unverified = calendar.presentation("You are free.", user: "Check calendar availability", now: checked)
        XCTAssertEqual(unverified.failure?.reason, "calendar_slot_unverified",
                       "A new receipt cannot inherit the previous receipt's exact-slot assessment")
    }

    @MainActor func testSelectionChangeCannotReuseAvailabilityFromPreviousEmail() {
        var calendar = LiveCalendarConversation()
        calendar.recordRead(id: "first", arguments: arguments, output: available,
                            accounts: ["owner@example.test"], now: checked, zone: zone)
        _ = calendar.checkSlot(arguments: #"{"receipt_id":"first","start":"2026-11-09T13:00:00-08:00","end":"2026-11-09T14:00:00-08:00"}"#, now: checked)
        calendar.selectionChanged()
        XCTAssertNil(calendar.context(selection: "email B", user: "Check calendar availability", now: checked)["calendarEvidence"])
        XCTAssertEqual(calendar.presentation("You are free.", user: "Check calendar availability", now: checked).failure?.reason,
                       "calendar_slot_unverified")
    }

    @MainActor func testPreparedWriteDoesNotTakeEffectBeforePersistenceAndScopeChecks() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let jobs = DispatchJobStore(url: folder.appendingPathComponent("jobs.json"))
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = #"{"done":false,"item":{"id":"A","threadId":"thread-A","account":"owner@example.test","subject":"Meeting"}}"#
        var calendar = LiveCalendarConversation()
        calendar.user("Reply and send an invitation.", selection: source, proposal: "Monday works.", newTurn: true, jobs: jobs)
        let pending = try XCTUnwrap(calendar.preparingWrite(name: CalendarTools.create, id: "invite", arguments: "{}"))
        XCTAssertNil(calendar.intent?.inviteCall, "Preparing a write must not commit it before the brain's async gates")
        XCTAssertEqual(pending.inviteState, "unknown")
        calendar.acceptPreparedWrite(pending)
        calendar.selectionChanged()
        XCTAssertEqual(calendar.sourceState(fallback: "email B"), source)
        XCTAssertTrue(calendar.holdsFeedDecision)
        XCTAssertNotNil(calendar.refusal(name: CalendarTools.create, arguments: "{}", now: checked, jobs: jobs),
                        "An uncertain invitation must not be repeated after feed advancement")
        calendar.scopeChanged()
        XCTAssertEqual(calendar.sourceState(fallback: "email B"), "email B")
        XCTAssertFalse(calendar.holdsFeedDecision)
        XCTAssertNil(calendar.intent)
    }
}
