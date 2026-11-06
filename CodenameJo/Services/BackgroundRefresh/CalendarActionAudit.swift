import FactoryKit
import Foundation

enum CalendarActionContext {
    @TaskLocal static var current: CalendarActionAudit?
}

/// The task-local journal follows one calendar call through preflight, transport and archive.
@MainActor
final class CalendarActionAudit {
    let job: DispatchJob
    private let store: DispatchJobStore
    private var action: CalendarActionReceipt
    private var observed: [String: Any]?
    private var writeBody: [String: Any] = [:]
    private var requestedID: String?
    private var notifications = false
    private var persistenceFailed = false
    private var conflict = false

    private init(job: DispatchJob, store: DispatchJobStore) {
        self.job = job; self.store = store; action = job.calendarAction!
    }

    static func run(name: String, argumentsJSON: String, callID: String?, conversationID: String?,
                    parentJobID: UUID? = nil, origin: DispatchJob.MailOrigin? = nil,
                    operation: (String) async -> FullDuplexBroker.ToolResult) async -> FullDuplexBroker.ToolResult {
        let store = Container.shared.dispatchJobs()
        guard let owner = Container.shared.backend().userId else {
            return .init(text: "No calendar change: sign in before recording an action.", ok: false)
        }
        var args = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] ?? [:]
        let accounts = CalendarTools.accounts()
        let mailbox = await Container.shared.localTriage().currentMailbox
        if case .success(let bound) = CalendarTools.bind(name, args, mailbox: mailbox, accounts: accounts) { args = bound }
        let account = (try? CalendarTools.singleTarget(args, accounts, creating: name == CalendarTools.create))
            ?? args["account"] as? String ?? "No connected account"
        if accounts.contains(account) { args["account"] = account }
        let action = CalendarActionReceipt(tool: name, arguments: args, account: account,
            requestKey: callID, parentJobID: parentJobID)
        let source = origin ?? (args["source_message_id"] as? String).flatMap { id in
            (args["source_account"] as? String).map {
                DispatchJob.MailOrigin(account: $0.lowercased(), messageID: id, threadID: "", sender: "", subject: "Calendar invitation")
            }
        }
        do {
            let (job, fresh) = try await store.beginCalendarAction(action, ownerID: owner,
                profileID: ProfileRuntime.snapshot?.profileId, conversationID: conversationID, origin: source)
            guard fresh else {
                return .init(text: (job.result ?? "This calendar operation is already recorded.")
                    + " No duplicate calendar write was attempted.", ok: job.calendarAction?.confirmed == true
                        && job.calendarAction?.archiveState?.hasPrefix("unconfirmed") != true,
                    outcomeUnknown: job.calendarAction?.state == .unknown || job.calendarAction?.state == .pending)
            }
            let audit = CalendarActionAudit(job: job, store: store)
            let result = await CalendarActionContext.$current.withValue(audit) { await operation(GmailReadTools.json(args)) }
            return await audit.finish(result)
        } catch let error as CalendarTools.Refusal {
            return .init(text: error.text, ok: false)
        } catch {
            return .init(text: "No calendar change: the action could not be recorded.", ok: false)
        }
    }

    func beforeWrite(_ method: String, path: String, query: [String: String], body: [String: Any]?) async throws {
        guard Container.shared.backend().userId == job.userId,
              ProfileRuntime.snapshot?.profileId == job.profileId else {
            throw CalendarTools.Refusal(text: "No calendar change: the active account or profile changed.")
        }
        try Task.checkCancellation()
        action.attempted = true
        writeBody = body ?? [:]
        requestedID = method == "POST" ? body?["id"] as? String : path.split(separator: "/").last.map(String.init)
        action.providerID = requestedID ?? action.providerID
        notifications = query["sendUpdates"] == "all"
        guard await store.recordCalendarAction(job.id, action: action, result: "Calendar write pending confirmation.") else {
            action.attempted = false
            throw CalendarTools.Refusal(text: "No calendar change: its pending receipt could not be saved.")
        }
        guard !Task.isCancelled, Container.shared.backend().userId == job.userId,
              ProfileRuntime.snapshot?.profileId == job.profileId else {
            action.attempted = false
            throw CalendarTools.Refusal(text: "No calendar change: the request stopped or its account/profile changed.")
        }
    }

    func observedEvent(_ event: [String: Any]) {
        guard let id = event["id"] as? String, id == action.providerID else { return }
        observed = event
        action.capture(event)
    }

    func received(_ event: [String: Any], method: String) async {
        if method == "DELETE" {
            if let observed { action.capture(observed) }
            action.state = .confirmed
        } else {
            action.capture(event)
            let id = event["id"] as? String
            var matches = id?.isEmpty == false && (requestedID == nil || requestedID == id)
            for key in ["summary", "description", "location", "visibility"] {
                if let expected = writeBody[key] as? String, event[key] as? String != expected { matches = false }
            }
            var times: [String: Any] = [:]
            for key in ["start", "end"] {
                let value = writeBody[key] as? [String: Any] ?? [:]
                times[key] = value["dateTime"] as? String ?? value["date"] as? String
            }
            matches = matches && CalendarWriteTiming.matches(request: times, event: event)
            if let expected = writeBody["attendees"] as? [[String: Any]] {
                let actual = event["attendees"] as? [[String: Any]] ?? []
                let addresses: ([[String: Any]]) -> Set<String> = { Set($0.compactMap { ($0["email"] as? String)?.lowercased() }) }
                matches = matches && addresses(expected) == addresses(actual)
                for guest in expected where guest["responseStatus"] != nil {
                    let actualGuest = actual.first { ($0["email"] as? String)?.lowercased() == (guest["email"] as? String)?.lowercased() }
                    if guest["responseStatus"] as? String != actualGuest?["responseStatus"] as? String { matches = false }
                }
            }
            action.state = matches ? .confirmed : .unknown
        }
        action.invitationOutcome = action.confirmed
            ? (notifications ? "Google confirmed the write with attendee notifications requested; email delivery is not verified." : "No attendee notifications requested.")
            : "The provider response did not confirm every requested change."
        await save(action.confirmed ? action.activityTitle : "Calendar outcome unknown. Inspect the event before retrying.")
    }

    func confirmedExisting(_ event: [String: Any], expected: [String: Any]) async {
        guard !action.attempted || (conflict && event["id"] as? String == requestedID),
              event["status"] as? String != "cancelled" else { return }
        let targetMatches = action.providerID == nil || action.providerID == event["id"] as? String
        action.capture(event)
        action.state = targetMatches && (event["id"] as? String)?.isEmpty == false
            && CalendarWriteTiming.matches(request: expected, event: event)
            && (action.requestedResponse == nil || action.response == action.requestedResponse) ? .confirmed : .unknown
        action.alreadyRecorded = action.confirmed
        action.invitationOutcome = action.confirmed ? "Already recorded by Google. No new notifications sent."
            : "The existing event did not confirm the requested values."
        await save(action.activityTitle)
    }

    func failed(_ error: Error) async {
        guard !action.confirmed else { return }
        if case CalendarAPI.Failure.http(409) = error { conflict = true }
        switch error {
        case CalendarAPI.Failure.unauthorized, CalendarAPI.Failure.throttled: action.state = .failed
        case CalendarAPI.Failure.http(let code) where (400..<500).contains(code) && code != 408 && code != 409:
            action.state = .failed
        default: action.state = action.attempted ? .unknown : .failed
        }
        await save(action.state == .unknown
            ? "Google Calendar did not confirm this write. Inspect the event before retrying."
            : "Google Calendar did not accept this operation.")
    }

    private func save(_ result: String) async {
        if !(await store.recordCalendarAction(job.id, action: action, result: result)) { persistenceFailed = true }
    }

    private func finish(_ result: FullDuplexBroker.ToolResult) async -> FullDuplexBroker.ToolResult {
        if !action.confirmed {
            if action.state == .pending { action.state = action.attempted ? .unknown : .failed }
        }
        if action.tool == LocalCalendarWrites.respond, action.confirmed, action.requestedResponse == "accepted" {
            if result.effects?.contains(where: { $0.removeLabelIds?.contains("INBOX") == true }) == true { action.archiveState = "confirmed" }
            else if result.ok == false { action.archiveState = "unconfirmed — source email kept" }
        }
        let reported: String
        if action.state == .unknown {
            reported = (result.ok == false ? result.text + " " : "")
                + "Calendar outcome remains unknown; check its stored values before retrying. Jo will not repeat this write automatically."
        } else if action.state == .failed, result.ok == true {
            reported = result.text + " No calendar change was confirmed."
        } else { reported = result.text }
        await save(reported)
        if persistenceFailed {
            return .init(text: reported + " The local receipt could not be fully saved. Do not repeat the calendar write.",
                ok: false, effects: result.effects, outcomeUnknown: true)
        }
        if action.state == .unknown {
            return .init(text: reported,
                ok: false, effects: result.effects, outcomeUnknown: true)
        }
        if action.state == .failed, result.ok == true {
            return .init(text: reported, ok: false, effects: result.effects)
        }
        return result
    }
}
