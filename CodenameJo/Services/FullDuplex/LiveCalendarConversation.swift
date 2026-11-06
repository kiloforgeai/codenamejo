import Foundation

/// Owns calendar evidence and the accepted reply/invitation workflow, independently of request transport.
@MainActor
struct LiveCalendarConversation {
    private(set) var window: CalendarRequestWindow?
    private var readIncomplete = false
    private var readAt: Date?
    private var checkedWindow: CalendarRequestWindow?
    private var evidence: CalendarAvailabilityEvidence?
    private var assessment: CalendarAvailabilityEvidence.Assessment?
    private var checkedSlots: [CalendarAvailabilityEvidence.Assessment] = []
    private(set) var intent: CalendarConversationIntent?
    private(set) var focused = false
    private var inputProposal = ""
    private var inputFinalized = true
    private var emailOnly = false

    var holdsFeedDecision: Bool { focused && intent?.complete == false }

    func checkingAvailability(for text: String) -> Bool {
        (focused && intent?.needsInvitation == true) || window != nil || (CalendarAvailabilityEvidence.claimsAvailability(text)
            && (evidence != nil || text.range(of: #"\b(?:calendar|meet|meeting|schedule|time|slot|conflict|busy|today|tomorrow|Monday|Tuesday|Wednesday|Thursday|Friday)\b"#,
                options: [.regularExpression, .caseInsensitive]) != nil))
    }

    func sourceState(fallback: String) -> String { focused ? intent?.sourceState ?? fallback : fallback }

    /// The caller must establish that this call belongs to its active request before using this source.
    func source(for call: LiveSessionAdapter.Call) -> String? {
        guard focused, let intent else { return nil }
        if CalendarTools.names.contains(call.name) { return intent.sourceState }
        if call.name == GmailReadTools.getMessage,
           ToolArguments(call.arguments).string("message_id") == intent.source.messageID,
           ToolArguments(call.arguments).string("account")?.lowercased() == intent.source.account.lowercased() { return intent.sourceState }
        return nil
    }

    mutating func scopeChanged() {
        intent = nil
        focused = false
        checkedWindow = nil
        evidence = nil
        assessment = nil
        checkedSlots.removeAll()
        inputProposal = ""
        emailOnly = false
    }

    mutating func selectionChanged() {
        guard !focused else { return }
        window = nil
        readIncomplete = false
        checkedWindow = nil
        evidence = nil
        assessment = nil
        checkedSlots.removeAll()
    }

    mutating func user(_ text: String, selection: String, proposal: String, newTurn: Bool, jobs: DispatchJobStore, finalized: Bool = true) {
        if newTurn { checkedSlots.removeAll(); inputProposal = proposal }
        inputFinalized = finalized
        emailOnly = CalendarConversationIntent.emailOnly(text)
        let wasFocused = focused
        if let intent, jobs.existing(intent.id)?.state == "cancelled" { self.intent = nil }
        intent = intent.map(jobs.reconciledCalendarIntent) ?? jobs.pendingCalendarIntent
        let correcting = finalized && emailOnly && (wasFocused || intent?.refers(text, selection: selection) == true)
        if correcting { intent?.withdrawInvitation() }
        if finalized, CalendarConversationIntent.accepts(text), var updated = intent,
           !updated.needsInvitation, updated.inviteCall == nil, !updated.complete {
            updated.invitationRequested = true; updated.inviteState = "pending"
            updated.revision = (updated.revision ?? 0) + 1
            intent = updated
        }
        if finalized, intent?.complete != false, CalendarConversationIntent.accepts(text),
           let origin = DispatchJob.MailOrigin.captured(in: selection) {
            intent = .init(id: UUID(), source: origin, sourceState: selection, request: text,
                proposal: inputProposal, window: window ?? checkedWindow, availability: evidence, assessment: assessment)
        }
        focused = intent?.complete == false && (correcting || intent?.refers(text, selection: selection) == true)
        if wasFocused && !focused {
            window = nil; checkedWindow = nil
            evidence = nil; assessment = nil
        }
        if focused {
            if finalized, var updated = intent, updated.followups.last != text {
                updated.followups.append(text)
                updated.revision = (updated.revision ?? 0) + 1
                intent = updated
            }
            let followups = Array(intent?.followups.suffix(8) ?? [])
            intent?.followups = followups
            window = intent?.window
            evidence = intent?.availability ?? evidence
            assessment = intent?.assessment ?? assessment
        }
        if emailOnly || (focused && intent?.needsInvitation == false) {
            window = nil; checkedWindow = nil; evidence = nil; assessment = nil
        }
    }

    mutating func resolveWindow(for text: String, newTurn: Bool, reference: Date, zone: TimeZone) {
        if (emailOnly || (focused && intent?.needsInvitation == false)),
           !CalendarAvailabilityEvidence.claimsAvailability(text) { return }
        if newTurn {
            let followup = text.range(of: #"\b(?:send|reply|draft|those|slots|times|yes)\b"#,
                options: [.regularExpression, .caseInsensitive]) != nil
            if !followup && !focused { window = nil }
        }
        if let resolved = CalendarRequestWindow(request: text, reference: reference, zone: zone), window != resolved {
            window = resolved
            readIncomplete = true
            readAt = nil
        }
    }

    mutating func recordRead(id: String, arguments: String?, output: String,
                             accounts: [String], now: Date, zone: TimeZone) {
        readIncomplete = !CalendarRequestWindow.completeRead(output, window: window)
        readAt = now
        evidence = CalendarAvailabilityEvidence(id: id, arguments: arguments ?? "{}", output: output,
            expectedAccounts: accounts, now: now, zone: zone)
        assessment = nil
        checkedSlots.removeAll()
        if focused { intent?.availability = evidence; intent?.assessment = nil }
        if CalendarRequestWindow.completeRead(output), let arguments {
            checkedWindow = CalendarRequestWindow(checkedArguments: arguments, reference: now, zone: zone)
            if focused { intent?.window = checkedWindow }
        }
    }

    mutating func reconcile(jobs: DispatchJobStore) {
        intent = intent.map(jobs.reconciledCalendarIntent)
    }

    func context(selection: String, user: String, now: Date) -> [String: Any] {
        var value: [String: Any] = [:]
        if emailOnly { value["requestedActionRule"] = "This is email composition about an invitation, not authorization to create a calendar event. Use the dictated text; do not ask for meeting duration or invent a pending invitation." }
        if let evidence, checkingAvailability(for: user) {
            value["calendarEvidence"] = evidence.context
            value["calendarEvidenceFresh"] = evidence.fresh(at: now)
            if let assessment {
                value["checkedSlot"] = ["receipt_id": assessment.receiptID, "start": assessment.start,
                    "end": assessment.end, "status": assessment.status, "spoken": assessment.spoken]
            }
            value["checkedSlots"] = checkedSlots.map { ["start": $0.start, "end": $0.end, "status": $0.status] }
        }
        if focused, let intent {
            value["calendarIntent"] = intent.context
            value["feedSelection"] = LiveCompactContext.selectionReference(selection)
            value["currentSelection"] = sourceState(fallback: selection)
            value["selectionRule"] = "The accepted calendar intent is the current request's source. The feed may show another email; do not use that email to answer meeting follow-ups."
        }
        return value
    }

    var intentDiagnostics: [String: String] {
        guard focused, let intent else { return [:] }
        return ["calendar_workflow_id": intent.id.uuidString, "calendar_reply_state": intent.replyState,
                "calendar_invite_state": intent.inviteState, "input_finalized": String(inputFinalized),
                "reason": intent.needsInvitation ? "explicit_reply_and_invitation" : "email_only_correction"]
    }

    mutating func windowContext(now: Date) -> [String: Any] {
        guard let window else { return [:] }
        if let readAt, now.timeIntervalSince(readAt) > CalendarTools.cacheFreshness { readIncomplete = true }
        return ["calendarWindow": window.context,
            "calendarCoverage": readIncomplete
                ? "Incomplete or stale. Do not propose availability or send scheduling times until all requested calendars have been checked."
                : "Use the recorded tool results; this clock is not evidence of availability."]
    }

    var windowDiagnostics: [String: String] {
        guard let window else { return [:] }
        return ["reference_now": window.stamp(window.reference), "range_start": window.stamp(window.start),
                "range_end": window.stamp(window.end), "time_zone": window.zone.identifier]
    }

    // Availability needs free/busy coverage; an event-title list can contain transparent entries.
    func prepare(_ item: [String: Any], user: String) -> [String: Any] {
        guard checkingAvailability(for: user), item["name"] as? String == CalendarTools.list,
              let raw = item["arguments"] as? String,
              var args = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else { return item }
        args["availability_check"] = true
        args.removeValue(forKey: "query"); args.removeValue(forKey: "ical_uid")
        var updated = item
        updated["arguments"] = GmailReadTools.json(args)
        return updated
    }

    struct SlotCheck {
        let output: String
        let receiptID: String?
        let status: String
    }

    mutating func checkSlot(arguments: String, now: Date) -> SlotCheck {
        let args = ToolArguments(arguments)
        assessment = evidence?.assess(receiptID: args.string("receipt_id") ?? "",
            start: args.string("start") ?? "", end: args.string("end") ?? "", now: now)
        if let assessment {
            checkedSlots.removeAll { $0.start == assessment.start && $0.end == assessment.end }
            checkedSlots.append(assessment)
            checkedSlots = Array(checkedSlots.suffix(8))
        }
        if focused { intent?.assessment = assessment }
        return SlotCheck(output: assessment.map {
            GmailReadTools.json(["receipt_id": $0.receiptID, "status": $0.status, "spoken": $0.spoken])
        } ?? "Availability is unverified. Read the requested calendar window first.",
            receiptID: assessment?.receiptID, status: assessment?.status ?? "unverified")
    }

    struct Refusal {
        let message: String
        var outsideRange = false
    }

    func refusal(name: String, arguments: String?, now: Date, jobs: DispatchJobStore) -> Refusal? {
        if name == CalendarTools.create, emailOnly {
            return Refusal(message: "No calendar event was created: the user requested only an email reply about an invitation.")
        }
        if focused, let intent, let arguments,
           let message = jobs.reconciledCalendarIntent(intent).refusal(name: name, arguments: arguments) {
            return Refusal(message: message)
        }
        if window != nil, readIncomplete, CalendarRequestWindow.schedulingReply(name: name, arguments: arguments ?? "") {
            return Refusal(message: "Not executed: scheduling times require complete fresh coverage across the requested calendars. Read the resolved window before proposing or sending availability.")
        }
        if let arguments, let message = window?.toolRefusal(name: name, arguments: arguments, now: now) {
            return Refusal(message: message, outsideRange: true)
        }
        return nil
    }

    /// The brain persists this pending write and rechecks its request scope before accepting it.
    func preparingWrite(name: String, id: String, arguments: String) -> CalendarConversationIntent? {
        guard focused, var intent, ["send_email", "reply_email", CalendarTools.create].contains(name) else { return nil }
        intent.revision = (intent.revision ?? 0) + 1
        if name == CalendarTools.create { intent.inviteCall = id; intent.inviteState = "unknown"; intent.invitationArguments = arguments }
        else { intent.replyCall = id; intent.replyState = "unknown" }
        return intent
    }

    mutating func acceptPreparedWrite(_ intent: CalendarConversationIntent) { self.intent = intent }

    struct Presentation {
        var text: String
        var replaced = false
        var diagnostics: [String: String] = [:]
        var failure: (message: String, reason: String)?
    }

    func presentation(_ text: String, user: String, now: Date) -> Presentation {
        var result = Presentation(text: text)
        if checkingAvailability(for: user), CalendarAvailabilityEvidence.claimsAvailability(text) {
            guard let evidence, let assessment, assessment.receiptID == evidence.id, evidence.fresh(at: now) else {
                result.failure = ("I haven't verified that exact slot against a fresh, complete calendar check. Availability is unverified; no conflict is confirmed.",
                                  "calendar_slot_unverified")
                return result
            }
            // Only the interval check owns availability wording, including every proposed slot.
            let currentSlots = checkedSlots.filter { $0.receiptID == evidence.id }
            result.text = (currentSlots.isEmpty ? [assessment] : currentSlots).map(\.spoken).joined(separator: " ")
            if focused, intent?.replyState == "confirmed" { result.text = "The reply has been sent. " + result.text }
            result.replaced = true
            result.diagnostics = ["calendar_receipt_id": evidence.id, "calendar_slot_status": assessment.status]
        }
        if window != nil, readIncomplete,
           result.text.range(of: #"\b(?:available|free|slots?)\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
            result.failure = ("I couldn't confirm availability across all the requested calendars. One or more reads were incomplete or stale; no free times are confirmed.",
                              "calendar_coverage_incomplete")
        } else if let window, window.containsOutsideDate(result.text) {
            result.failure = ("I couldn't confirm those proposed dates. " + window.rangeExplanation + " Please ask me to recheck availability.",
                              "calendar_date_outside_range")
        }
        return result
    }
}
