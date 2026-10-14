import XCTest
@testable import CodenameJo

final class FeedFocusTests: XCTestCase {
    func testOnboardingAboutStepShowsTheWholeDraft() {
        var tracker = FeedFocusTracker()
        let output = #"{"done":false,"position":2,"about":{"items":["Plays golf","Reads fiction"]},"onboarding":{"step":2}}"#
        XCTAssertEqual(tracker.applyTriage(output: output), .about(["Plays golf", "Reads fiction"]))
    }

    func testBackgroundGroupingUpdatesCountWithoutReplacingCurrentCard() throws {
        var tracker = FeedFocusTracker()
        _ = tracker.applyTriage(output: #"{"position":1,"item":{"account":"work@example.com","from":"Shop","subject":"Order"}}"#,
                                queueTotal: 10)
        let progress = LocalTriageQueue.Progress(account: "work@example.com", position: 1,
            queued: 10, remaining: 10, done: false,
            displayPosition: 1, displayQueued: 5, displayRemaining: 5)
        let card = try email(from: tracker.refreshEmailProgress(progress))
        XCTAssertEqual(card.subject, "Order")
        XCTAssertEqual(card.position, 1)
        XCTAssertEqual(card.total, 5)
    }

    func testGroupedDisplayProgressOverridesMessageOrdinal() throws {
        var tracker = FeedFocusTracker()
        let output = #"{"done":false,"position":6,"item":{"from":"Shop","subject":"Another order"}}"#
        let card = try email(from: tracker.applyTriage(
            output: output, queuePosition: 6, queueTotal: 6,
            displayPosition: 2, displayTotal: 2))
        XCTAssertEqual(card.position, 2)
        XCTAssertEqual(card.total, 2)
    }

    func testActiveEmailUsesStructuredQueueItem() throws {
        var tracker = FeedFocusTracker()
        let focus = tracker.applyTriage(
            output: #"{"done":false,"position":3,"item":{"account":"work@example.com","from":"Priya <priya@example.com>","subject":"Contract update","snippet":"I made the requested edit."}}"#,
            queuePosition: 3,
            queueTotal: 8)

        let email = try email(from: focus)
        XCTAssertEqual(email.sender, "Priya <priya@example.com>")
        XCTAssertEqual(email.subject, "Contract update")
        XCTAssertEqual(email.snippet, "I made the requested edit.")
        XCTAssertEqual(email.account, "work@example.com")
        XCTAssertEqual(email.position, 3)
        XCTAssertEqual(email.total, 8)
    }

    func testEmptyInboxAndTerminalCompletionStayDistinct() throws {
        var tracker = FeedFocusTracker()
        XCTAssertEqual(
            tracker.applyTriage(output: #"{"done":true,"queued":0,"empty":true,"interstitial":"feed","calendarDue":false}"#),
            .emailStatus(.empty))

        let completed = try summary(from: tracker.finishTerminalResponse())
        XCTAssertEqual(completed.email, .empty)
        XCTAssertEqual(completed.calendar, .notRun)
    }

    func testPreloadedTipUsesCanonicalCopy() throws {
        var tracker = FeedFocusTracker()
        let focus = tracker.applyTriage(output: #"{"done":true,"queued":2,"interstitial":"feed","calendarDue":false,"coaching":{"lesson":{"capability":"archive","copy":"Archive handled mail so the inbox stays focused."}}}"#)
        let tip = try tip(from: focus)
        XCTAssertEqual(tip.capability, "archive")
        XCTAssertEqual(tip.copy, "Archive handled mail so the inbox stays focused.")
    }

    func testCalendarAgendaIsChronologicalAndDeduplicated() throws {
        var tracker = FeedFocusTracker()
        let later = FeedFocus.CalendarEvent(
            id: "later", account: "work@example.com", title: "Review", location: "Zoom",
            start: Date(timeIntervalSince1970: 200), end: nil, allDay: false)
        let earlier = FeedFocus.CalendarEvent(
            id: "earlier", account: "work@example.com", title: "Standup", location: nil,
            start: Date(timeIntervalSince1970: 100), end: nil, allDay: false)

        XCTAssertEqual(
            tracker.calendarResult(events: [later, earlier, earlier], successful: true),
            .calendar(.agenda(events: [earlier, later], partial: false)))
        XCTAssertEqual(tracker.summary.calendar, .agenda(count: 2, partial: false))
    }

    func testEmptyAndUnavailableCalendarAreDifferentStates() {
        var tracker = FeedFocusTracker()
        XCTAssertEqual(
            tracker.calendarResult(events: [], successful: true),
            .calendar(.empty(partial: false)))
        XCTAssertEqual(
            tracker.calendarResult(events: [], successful: false),
            .calendar(.unavailable))
    }

    func testPartialMultiAccountMCPResultKeepsSuccessfulAgenda() throws {
        var tracker = FeedFocusTracker()
        let output = #"[{"account":"work@example.com","events":[{"id":"1","summary":"Design review","start":"2026-09-01T17:00:00Z","end":"2026-09-01T17:30:00Z","location":"Studio"}]},{"account":"personal@example.com","error":"unavailable"}]"#

        guard case .calendar(.agenda(let events, let partial)) = tracker.calendarMCPResult(output)
        else { return XCTFail("Expected a partial agenda") }
        XCTAssertTrue(partial)
        XCTAssertEqual(events.map(\.title), ["Design review"])
        XCTAssertEqual(events.map(\.account), ["work@example.com"])
    }

    func testPageInterludeReturnsToNextEmailInsteadOfCompleting() throws {
        var tracker = FeedFocusTracker()
        let output = #"{"done":false,"position":12,"interstitial":"page","calendarDue":false,"coaching":{"lesson":{"copy":"Use archive for handled mail."}}}"#
        _ = tracker.applyTriage(output: output)
        XCTAssertFalse(tracker.finishTerminalResponse()?.isComplete == true)

        let next = tracker.applyTriage(output: #"{"done":false,"position":13,"item":{"account":"work@example.com","from":"Nate","subject":"Thursday","snippet":"Can you confirm?"}}"#)
        XCTAssertEqual(try email(from: next).position, 13)
    }

    func testPageInterludeWithoutAnotherStageKeepsTheCurrentEmail() {
        var tracker = FeedFocusTracker()
        let current = tracker.applyTriage(output: #"{"done":false,"position":12,"item":{"account":"work@example.com","from":"Nate","subject":"Thursday","snippet":"Can you confirm?"}}"#)
        let page = tracker.applyTriage(output: #"{"done":false,"position":12,"interstitial":"page","calendarDue":false}"#)
        XCTAssertEqual(page, current)
        XCTAssertFalse(tracker.finishTerminalResponse()?.isComplete == true)
    }

    func testTerminalSummaryPreservesUnavailableCalendar() throws {
        var tracker = FeedFocusTracker()
        _ = tracker.applyTriage(output: #"{"done":true,"queued":4,"interstitial":"feed","calendarDue":true}"#)
        _ = tracker.calendarLoading()
        _ = tracker.calendarResult(events: [], successful: false)

        let completed = try summary(from: tracker.finishTerminalResponse())
        XCTAssertEqual(completed.email, .complete)
        XCTAssertEqual(completed.calendar, .unavailable)
    }

    func testLifecycleOnlyDismissesSettledFocus() {
        var tracker = FeedFocusTracker()
        let active = tracker.applyTriage(output: #"{"done":false,"position":1,"item":{"account":"work@example.com","from":"Nate","subject":"Thursday","snippet":"Can you confirm?"}}"#)
        XCTAssertEqual(tracker.dismissSettled(), active, "ordinary replies keep the active email")

        _ = tracker.applyTriage(output: #"{"done":true,"queued":1,"interstitial":"feed","calendarDue":false}"#)
        XCTAssertTrue(tracker.finishTerminalResponse()?.isComplete == true)
        XCTAssertNil(tracker.dismissSettled(), "the first post-completion turn clears it")

        _ = tracker.applyTriage(output: #"{"done":false,"position":1,"item":{"account":"work@example.com","from":"Nate","subject":"Thursday","snippet":"Can you confirm?"}}"#)
        XCTAssertNil(tracker.reset(), "stop, hang-up, failure, and redial reset the reducer")
    }

    func testSettledEmailStageClearsWhenTheUserMovesOn() {
        var tracker = FeedFocusTracker()
        _ = tracker.applyTriage(output: #"{"done":true,"queued":1,"interstitial":"feed","calendarDue":true}"#)
        XCTAssertEqual(tracker.focus, .emailStatus(.complete))
        XCTAssertNil(tracker.dismissSettled(), "an unrelated ask after the email pass drops the card")
        XCTAssertEqual(tracker.finishTerminalResponse(), nil, "a stale terminal response does not resurrect it")

        XCTAssertEqual(tracker.calendarLoading(), .calendar(.loading))
        XCTAssertEqual(tracker.dismissSettled(), .calendar(.loading), "a calendar still loading stays")
        _ = tracker.calendarResult(events: [], successful: true)
        XCTAssertNil(tracker.dismissSettled(), "a landed calendar answer clears like any other settled stage")
    }

    func testFailedQueuePreparationClearsStaleFocus() {
        var tracker = FeedFocusTracker()
        _ = tracker.applyTriage(output: #"{"done":false,"position":1,"item":{"account":"work@example.com","from":"Nate","subject":"Thursday","snippet":"Can you confirm?"}}"#)
        XCTAssertNil(tracker.applyTriage(output: #"{"done":true,"error":"queue unavailable"}"#))
    }

    func testEmailCardProgressKeepsCumulativePositionAndTwelveMessagePageEnds() {
        for (position, total, expectedPosition, expectedTotal) in [
            (3, 758, 3, 12), (12, 758, 12, 12), (13, 758, 13, 24),
            (24, 758, 24, 24), (25, 758, 25, 36), (757, 758, 757, 758),
            (758, 758, 758, 758), (3, 8, 3, 8), (14, 13, 14, 14)
        ] {
            let value = FeedFocus.Email(sender: "Sender", subject: "Subject", snippet: "",
                account: "owner@example.test", position: position, total: total)
            XCTAssertEqual(value.position, expectedPosition)
            XCTAssertEqual(value.pageTotal, expectedTotal)
            XCTAssertEqual(value.position, position, "Presentation must preserve the queue ordinal")
            XCTAssertEqual(value.total, total, "Presentation must preserve the queue total")
        }
    }

    func testUnknownTotalDoesNotInventAPageLength() {
        for total: Int? in [nil, 0] {
            let value = FeedFocus.Email(sender: "Sender", subject: "Subject", snippet: "",
                account: "owner@example.test", position: 15, total: total)
            XCTAssertEqual(value.position, 15)
            XCTAssertNil(value.pageTotal)
        }
    }

    func testSlackQueueStepsDriveTheCard() throws {
        var tracker = FeedFocusTracker()
        let first = ##"{"done":false,"position":1,"queued":3,"remaining":3,"started":true,"workspaces":["A","B"],"item":{"workspace":"A","channel_id":"C1","name":"#deploys","kind":"channel","unread":9,"more":true,"why":"mentions you","messages":[{"from":"Josh","ts":"3","text":"newest"},{"from":"Vercel","ts":"2","text":"middle"},{"from":"Josh","ts":"1","text":"older"},{"from":"Josh","ts":"0","text":"oldest"}]}}"##
        let card = try slack(from: tracker.applySlack(output: first))
        XCTAssertEqual(card.name, "#deploys")
        XCTAssertEqual(card.position, 1)
        XCTAssertEqual(card.total, 3)
        XCTAssertTrue(card.more)
        XCTAssertTrue(card.showsWorkspace)
        XCTAssertEqual(card.messages.map(\.text), ["older", "middle", "newest"])

        // A finisher's receipt with the next step appended, as renderInlineAdvance writes it.
        let next = #"{"done":false,"position":2,"queued":3,"remaining":2,"item":{"workspace":"B","channel_id":"D2","name":"Priya","kind":"dm","unread":1,"more":false,"why":"dm","messages":[{"from":"Priya","ts":"1","text":"ping"}]}}"#
        let advanced = try slack(from: tracker.applySlack(
            output: "Sent.\n\nQueue: that was 1 of 3, 2 left.\n" + next))
        XCTAssertEqual(advanced.name, "Priya")
        XCTAssertTrue(advanced.showsWorkspace, "only the first step lists workspaces")

        // A reply that did not advance, or a read, leaves the card on its conversation.
        XCTAssertEqual(try slack(from: tracker.applySlack(output: "Could not send.")).name, "Priya")
        XCTAssertFalse(tracker.dismissSettled() == nil)

        let done = #"{"done":true,"queued":3,"acted":2,"passed":1,"markedRead":2,"stillUnread":1}"#
        XCTAssertEqual(tracker.applySlack(output: done), .slackStatus(.complete))
        XCTAssertEqual(tracker.summary.slack, .complete)
        XCTAssertNil(tracker.dismissSettled())
    }

    func testImportantSlackInterstitialShowsItsFirstConversation() throws {
        var tracker = FeedFocusTracker()
        let output = ##"{"done":false,"interstitial":"slack","position":3,"slackStep":{"done":false,"position":1,"queued":1,"remaining":1,"started":true,"workspaces":["A"],"item":{"workspace":"A","channel_id":"D1","name":"Priya","kind":"dm","unread":1,"more":false,"why":"asks you something","messages":[{"from":"Priya","ts":"1","text":"can you review?"}]}}}"##
        let card = try slack(from: tracker.applyTriage(output: output))
        XCTAssertEqual(card.name, "Priya")
    }

    func testSlackStopAndNoQueue() {
        var tracker = FeedFocusTracker()
        XCTAssertNil(tracker.applySlack(output: #"{"stopped":false,"note":"nothing running"}"#))
        XCTAssertNil(tracker.applySlack(output: #"{"started":true,"total":0,"queued":0,"empty":true}"#))
        _ = tracker.applySlack(output: ##"{"done":false,"position":1,"queued":2,"item":{"name":"#a","messages":[]}}"##)
        XCTAssertEqual(tracker.applySlack(output: #"{"stopped":true,"remaining":2}"#), .slackStatus(.stopped))
    }

    func testTerminalMailStepCarryingSlackStepShowsSlack() throws {
        var tracker = FeedFocusTracker()
        let terminal = ##"{"done":true,"interstitial":"feed","queued":4,"slackStep":{"done":false,"position":1,"queued":2,"item":{"name":"#general","unread":2,"messages":[{"from":"Ana","text":"hi"}]}}}"##
        let card = try slack(from: tracker.applyTriage(output: terminal))
        XCTAssertEqual(card.name, "#general")
        XCTAssertEqual(tracker.summary.email, .complete)
        XCTAssertEqual(tracker.summary.slack, .reviewing)
    }

    private func slack(from focus: FeedFocus?) throws -> FeedFocus.Slack {
        guard case .slack(let slack) = focus else {
            throw NSError(domain: "FeedFocusTests", code: 4)
        }
        return slack
    }

    private func email(from focus: FeedFocus?) throws -> FeedFocus.Email {
        guard case .email(let email) = focus else {
            throw NSError(domain: "FeedFocusTests", code: 1)
        }
        return email
    }

    private func tip(from focus: FeedFocus?) throws -> FeedFocus.Tip {
        guard case .tip(let tip) = focus else {
            throw NSError(domain: "FeedFocusTests", code: 2)
        }
        return tip
    }

    private func summary(from focus: FeedFocus?) throws -> FeedFocus.Summary {
        guard case .complete(let summary) = focus else {
            throw NSError(domain: "FeedFocusTests", code: 3)
        }
        return summary
    }
}
