import Foundation
import FactoryKit

/// `respond_to_calendar_event` and `cancel_calendar_event` on the phone's Calendar grant. Only the PATCH or DELETE
/// lands after the receipt; the sentences are load-bearing (`CalendarRSVPQueuePolicy` and the queue read them).
enum LocalCalendarWrites {
    static let respond = "respond_to_calendar_event"
    static let cancel = "cancel_calendar_event"
    static let names: Set<String> = [respond, cancel]

    typealias Refusal = CalendarTools.Refusal
    private static let answers = ["accepted", "declined", "tentative"]

    /// - Parameter defer: the caller has spoken the receipt, so the Google write may land after it.
    static func run(name: String, argumentsJSON: String, defer deferred: Bool,
                    conversationId: String? = nil) async -> FullDuplexBroker.ToolResult {
        var args = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] ?? [:]
        let started = Date()
        var connected = await CalendarTools.accounts()
        guard !connected.isEmpty else {
            return .init(text: "No Google Calendar is connected. The user may need to reconnect their "
                + "Google account to grant calendar access.", ok: false)
        }
        switch CalendarTools.bind(name, args, mailbox: await Container.shared.localTriage().currentMailbox, accounts: connected) {
        case .failure(let refusal): return .init(text: refusal.text, ok: false)
        case .success(let bound):
            args = bound
            if let named = args["account"] as? String {
                connected = connected.filter { $0.caseInsensitiveCompare(named) == .orderedSame }
            }
        }
        do {
            let result = name == respond
                ? try await answer(args, connected, deferred: deferred, conversationId: conversationId)
                : try await cancelEvent(args, connected, deferred: deferred, conversationId: conversationId)
            RealtimeLog.log("localCalendarWrites: \(name) \(result.ok == true ? "ok" : "refused") in "
                + "\(Int(Date().timeIntervalSince(started) * 1000))ms — \(result.text.prefix(80))")
            return result
        } catch let refusal as Refusal {
            RealtimeLog.log("localCalendarWrites: \(name) refused — \(refusal.text.prefix(120))")
            return .init(text: refusal.text, ok: false)
        } catch {
            RealtimeLog.log("localCalendarWrites: \(name) failed — \(error)")
            return .init(text: "The \(name) call failed: \(detail(error))", ok: false)
        }
    }

    // MARK: - respond_to_calendar_event

    private static func answer(_ args: [String: Any], _ accounts: [String], deferred: Bool,
                               conversationId: String?) async throws -> FullDuplexBroker.ToolResult {
        let target = try CalendarTools.singleTarget(args, accounts)
        let eventId = (args["event_id"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let response = (args["response"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !eventId.isEmpty else {
            throw Refusal(text: "No event id — search or list the calendar first, then answer one of the results.")
        }
        guard answers.contains(response) else {
            throw Refusal(text: "\"\(response)\" isn't an answer. Pass response as \"accepted\", \"declined\" or \"tentative\".")
        }
        let capability = "answer invitations"
        let token = try await CalendarTools.accessToken(target, write: true, capability: capability)
        let path = "calendars/primary/events/\(eventId)"
        let event = try await translating(target, capability, "NOT ANSWERED", "answered it") {
            try await CalendarAPI.json("GET", path: path, token: token)
        }
        let title = event["summary"] as? String ?? "(no title)"
        let attendees = event["attendees"] as? [[String: Any]] ?? []
        guard let me = attendees.first(where: { $0["self"] as? Bool == true }) else {
            let organizer = (event["organizer"] as? [String: Any])?["self"] as? Bool == true
            throw Refusal(text: organizer
                ? "\"\(title)\" is an event \(target) created, so there is nothing to accept or decline. "
                    + "Deleting or cancelling it isn't something you can do."
                : "\(target) isn't on the invitation for \"\(title)\", so there is no response to give. "
                    + "It may be on another connected calendar.")
        }
        let when = start(event).map { " (\($0))" } ?? ""
        let scope = CalendarTools.isInstanceId(eventId) ? " This was that one occurrence, not the whole recurring series." : ""
        if me["responseStatus"] as? String == response {
            return .init(text: "\"\(title)\"\(when) was already \(response) on \(target). "
                + "Nothing changed and nobody was notified again.\(scope)", ok: true)
        }
        let said = response == "accepted" ? "Accepted" : response == "declined" ? "Declined" : "Tentatively accepted"
        let receipt = "\(said) \"\(title)\"\(when) as \(target). The organizer was notified.\(scope)"
        // The whole list goes back with one entry changed: a PATCH of `attendees` replaces it.
        let patched = attendees.map { attendee -> [String: Any] in
            guard attendee["self"] as? Bool == true else { return attendee }
            var mine = attendee
            mine["responseStatus"] = response
            return mine
        }
        let write = {
            _ = try await CalendarAPI.json("PATCH", path: path, query: ["sendUpdates": "all"],
                                           body: ["attendees": patched], token: token)
        }
        let landed = { await store().setOwnResponse(response, eventId: eventId, account: target) }
        return try await finish(write, landed: landed, receipt: receipt, target: target, capability: capability,
            prefix: "NOT ANSWERED", claim: "answered it",
            unchanged: "your answer wasn't sent and the organizer wasn't told",
            deferred: deferred, conversationId: conversationId)
    }

    // MARK: - cancel_calendar_event

    private static func cancelEvent(_ args: [String: Any], _ accounts: [String], deferred: Bool,
                                    conversationId: String?) async throws -> FullDuplexBroker.ToolResult {
        let target = try CalendarTools.singleTarget(args, accounts)
        let eventId = (args["event_id"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !eventId.isEmpty else {
            throw Refusal(text: "No event id — search or list the calendar first, then cancel one of the results.")
        }
        let capability = "cancel events"
        let token = try await CalendarTools.accessToken(target, write: true, capability: capability)
        let path = "calendars/primary/events/\(eventId)"
        let event = try await translating(target, capability, "NOT CANCELLED", "cancelled it") {
            try await CalendarAPI.json("GET", path: path, token: token)
        }
        let title = event["summary"] as? String ?? "(no title)"
        if event["status"] as? String == "cancelled" {
            throw Refusal(text: "\"\(title)\" was already cancelled. Nothing to do, and nobody was notified again.")
        }
        let when = start(event).map { " (\($0))" } ?? ""
        let scope = CalendarTools.isInstanceId(eventId) ? " That was the one occurrence, not the whole recurring series." : ""
        let organizer = (event["organizer"] as? [String: Any])?["self"] as? Bool == true
        let guests = (event["attendees"] as? [[String: Any]] ?? []).filter { $0["self"] as? Bool != true }.count
        let receipt: String
        if organizer {
            let told = guests == 0 ? "" : " The \(guests == 1 ? "guest was" : "\(guests) guests were") emailed a cancellation."
            receipt = "Cancelled \"\(title)\"\(when) on \(target).\(told)\(scope)"
        } else {
            receipt = "Took \"\(title)\"\(when) off \(target)'s calendar. The user didn't organize it, so it is still on "
                + "everyone else's and nobody was told why — declining it is what tells the organizer.\(scope)"
        }
        let write = {
            _ = try await CalendarAPI.json("DELETE", path: path, query: ["sendUpdates": "all"], token: token)
        }
        let landed = { await store().removeEvent(id: eventId, account: target) }
        return try await finish(write, landed: landed, receipt: receipt, target: target, capability: capability,
            prefix: "NOT CANCELLED", claim: "cancelled it",
            unchanged: "the event is still on the calendar and nobody was told",
            deferred: deferred, conversationId: conversationId)
    }

    // MARK: - Shared

    /// Run the write now, or hand it to a detached task whose failure is told on the conversation's next output.
    /// A deferred write updates the calendar cache when it lands; a synchronous one leaves that to its caller.
    private static func finish(_ write: @escaping @Sendable () async throws -> Void,
                               landed: @escaping @Sendable () async -> Int, receipt: String, target: String,
                               capability: String, prefix: String, claim: String, unchanged: String,
                               deferred: Bool, conversationId: String?) async throws -> FullDuplexBroker.ToolResult {
        guard deferred else {
            try await translating(target, capability, prefix, claim, write)
            return .init(text: receipt, ok: true)
        }
        let accepted = Date()
        Task.detached {
            do {
                try await write()
                let changed = await landed()
                RealtimeLog.log("localCalendarWrites: deferred write landed \(Int(Date().timeIntervalSince(accepted) * 1000))ms "
                    + "after accept; cache changed \(changed) event(s)")
            } catch {
                Container.shared.localWriteNotices().push(deferredFailure(error, target: target, capability: capability,
                                                                          unchanged: unchanged), conversation: conversationId)
            }
        }
        return .init(text: receipt, ok: true, deferred: true)
    }

    /// The failures worth saying in the user's terms, before anything was said.
    private static func translating<T>(_ target: String, _ capability: String, _ prefix: String, _ claim: String,
                                       _ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch CalendarAPI.Failure.unauthorized {
            throw Refusal(text: reconnect(target, capability))
        } catch CalendarAPI.Failure.http(404) {
            throw Refusal(text: "\(prefix) — that event id doesn't resolve on \(target)'s calendar. "
                + "List the calendar again and use an id from those results. "
                + "Tell the user you couldn't find the event; never say you \(claim).")
        } catch CalendarAPI.Failure.throttled {
            throw Refusal(text: "\(prefix) — Google Calendar is rate-limiting this account right now. "
                + "Offer to try again in a moment; never say you \(claim).")
        }
    }

    /// The same failures once the receipt has been spoken, worded as a correction.
    static func deferredFailure(_ error: Error, target: String, capability: String, unchanged: String) -> String {
        switch error {
        case CalendarAPI.Failure.unauthorized:
            return "that didn't go through — \(target) needs reconnecting before it can \(capability), so \(unchanged). "
                + "Remove and re-add the account in Settings, then try again."
        case CalendarAPI.Failure.http(404):
            return "that didn't go through — the event id doesn't resolve on \(target)'s calendar, so \(unchanged). "
                + "List the calendar again and act on an id from those results."
        default:
            return "that didn't go through (\(detail(error))) — \(unchanged)."
        }
    }

    private static func reconnect(_ account: String, _ capability: String) -> String {
        "\(account) needs reconnecting before it can \(capability) — its access predates that permission. "
            + "Remove and re-add the account in Settings, then try again."
    }

    private static func detail(_ error: Error) -> String {
        switch error {
        case CalendarAPI.Failure.http(let code): return "calendar \(code)"
        case CalendarAPI.Failure.throttled: return "Google Calendar is rate-limiting this account"
        case CalendarAPI.Failure.transport(let reason): return reason
        default: return String(String(describing: error).prefix(160))
        }
    }

    private static func start(_ event: [String: Any]) -> String? {
        let start = event["start"] as? [String: Any]
        return (start?["dateTime"] as? String ?? start?["date"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func store() async -> CalendarStore {
        CalendarStore(database: Container.shared.localContext().dbPool)
    }
}
