import CryptoKit
import Foundation

/// Local, durable evidence of one calendar operation. No receipt is an invitation-delivery guarantee.
struct CalendarActionReceipt: Codable, Hashable, Sendable {
    enum State: String, Codable, Sendable { case pending, confirmed, failed, unknown }
    let tool: String
    let account: String
    let calendarID: String
    let requestKey: String?
    let fingerprint: String
    let parentJobID: UUID?
    var state: State = .pending
    var title: String
    var requestedStart: String?
    var requestedEnd: String?
    var timeZone: String
    var start: String?
    var end: String?
    var attendees: [String]
    var requestedResponse: String?
    var response: String?
    var invitationOutcome: String = "Not confirmed"
    var providerID: String?
    var providerLink: String?
    var archiveState: String?
    var attempted = false
    var alreadyRecorded = false

    init(tool: String, arguments: [String: Any], account: String, requestKey: String?, parentJobID: UUID?) {
        self.tool = tool; self.account = account; calendarID = "primary"
        self.requestKey = requestKey; self.parentJobID = parentJobID
        var values = arguments; values["account"] = account.lowercased(); values["tool"] = tool
        let bytes = (try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])) ?? Data()
        fingerprint = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        title = arguments["summary"] as? String ?? "Calendar event"
        requestedStart = arguments["start"] as? String; requestedEnd = arguments["end"] as? String
        timeZone = arguments["time_zone"] as? String ?? TimeZone.current.identifier
        attendees = arguments["attendees"] as? [String] ?? []
        requestedResponse = arguments["response"] as? String
        providerID = arguments["event_id"] as? String
    }

    var confirmed: Bool { state == .confirmed }
    var label: String {
        switch state {
        case .pending: return "Pending"
        case .failed: return "Failed"
        case .unknown: return "Outcome unknown"
        case .confirmed:
            switch tool {
            case CalendarTools.create: return alreadyRecorded ? "Already on calendar" : "Created"
            case CalendarTools.update: return alreadyRecorded ? "Already up to date" : "Updated"
            case LocalCalendarWrites.respond: return "RSVP recorded"
            default: return "Cancelled"
            }
        }
    }
    var activityTitle: String { label + " · " + title }
    var providerURL: URL? {
        guard let providerLink, let url = URL(string: providerLink),
              url.scheme == "https", ["calendar.google.com", "www.google.com"].contains(url.host) else { return nil }
        return url
    }
    mutating func capture(_ event: [String: Any]) {
        title = event["summary"] as? String ?? title
        providerID = event["id"] as? String ?? providerID
        providerLink = event["htmlLink"] as? String ?? providerLink
        let from = event["start"] as? [String: Any] ?? [:], to = event["end"] as? [String: Any] ?? [:]
        start = from["dateTime"] as? String ?? from["date"] as? String ?? start
        end = to["dateTime"] as? String ?? to["date"] as? String ?? end
        timeZone = from["timeZone"] as? String ?? timeZone
        if let guests = event["attendees"] as? [[String: Any]] {
            attendees = guests.compactMap { guest in
                guard let email = guest["email"] as? String else { return nil }
                return email + ((guest["responseStatus"] as? String).map { " · " + $0 } ?? "")
            }
            response = guests.first { $0["self"] as? Bool == true }?["responseStatus"] as? String ?? response
        }
    }
}
