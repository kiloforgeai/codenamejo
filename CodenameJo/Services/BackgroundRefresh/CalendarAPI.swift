import Foundation
import FactoryKit

/// Google Calendar's REST API on the phone's own token: one `events.list` call, recurring events
/// expanded and soonest-first, under a `fields` mask of only what `CalendarStore` keeps.
enum CalendarAPI {
    private static func providerData(for request: URLRequest) async throws -> (Data, URLResponse) {
        return try await Container.shared.providerHTTP().data(for: request)

    }

    private static let base = URL(string: "https://www.googleapis.com/calendar/v3")!

    enum Failure: Error {
        /// The token was rejected. Usually a revoked grant.
        case unauthorized
        /// Google refused for rate rather than for permission.
        case throttled
        case http(Int)
        case transport(String)
        case decoding(String)
    }

    // MARK: - Shapes

    struct EventList: Decodable {
        let items: [Event]?
        let nextPageToken: String?
    }

    struct Event: Decodable {
        let id: String
        let status: String?
        let htmlLink: String?
        let summary: String?
        let location: String?
        let description: String?
        let recurringEventId: String?
        let start: EventTime?
        let end: EventTime?
        let attendees: [Attendee]?
        /// `"transparent"` for an event that doesn't block time; omitted when it does.
        let transparency: String?
        let hangoutLink: String?

        /// Google's own split: `date` for an all-day event, `dateTime` (RFC3339, with
        /// offset) for a timed one — never both.
        struct EventTime: Decodable {
            let date: String?
            let dateTime: String?
        }

        struct Attendee: Decodable {
            let email: String?
            let displayName: String?
            let responseStatus: String?
            let organizer: Bool?
        }
    }

    /// Mirrors the backend's `LIST_FIELDS` mask, so both stores answer the same kind of thing about an event.
    private static let fieldsMask =
        "items(id,status,htmlLink,summary,location,description,recurringEventId,"
        + "start,end,attendees(email,displayName,responseStatus,organizer),transparency,hangoutLink),nextPageToken"

    /// One page of the primary calendar's events overlapping `[timeMinISO, timeMaxISO]`.
    static func events(
        token: String, timeMinISO: String, timeMaxISO: String, pageToken: String? = nil
    ) async throws -> EventList {
        var params = [
            "singleEvents": "true",
            "orderBy": "startTime",
            "timeMin": timeMinISO,
            "timeMax": timeMaxISO,
            "maxResults": "250",
            "fields": fieldsMask,
        ]
        if let pageToken { params["pageToken"] = pageToken }
        return try await get(path: "calendars/primary/events", query: params, token: token)
    }

    // MARK: - Voice tools

    /// One Calendar REST call as loose JSON, for the voice tools' Google-shaped results.
    static func json(
        _ method: String, path: String, query: [String: String] = [:],
        body: [String: Any]? = nil, token: String
    ) async throws -> [String: Any] {
        await CalendarQuota.shared.spend()
        let data = try await send(method, path: path, query: query,
            body: try body.map { try JSONSerialization.data(withJSONObject: $0) }, token: token)
        if data.isEmpty { return [:] }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw Failure.decoding("\(path) — \(String(decoding: data.prefix(200), as: UTF8.self))")
        }
        return object
    }

    // MARK: - Transport

    /// Calendar answers a throttle with the same ambiguous 403 Gmail does, so it is matched by string too.
    private static func get<T: Decodable>(
        path: String, query: [String: String], token: String
    ) async throws -> T {
        let data = try await send("GET", path: path, query: query, body: nil, token: token)
        // A `fields` mask with nothing matching can come back as zero bytes rather than `{}`.
        let body = data.isEmpty ? Data("{}".utf8) : data
        do {
            return try JSONDecoder().decode(T.self, from: body)
        } catch {
            let head = String(decoding: data.prefix(200), as: UTF8.self)
                .replacingOccurrences(of: "\n", with: " ")
            throw Failure.decoding("\(path) — \(head)")
        }
    }

    private static func send(
        _ method: String, path: String, query: [String: String], body: Data?, token: String
    ) async throws -> Data {
        var components = URLComponents(
            url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false
        )!
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
            // Google reads a bare `+` as a space, which breaks a `+01:00` offset.
            components.percentEncodedQuery = components.percentEncodedQuery?
                .replacingOccurrences(of: "+", with: "%2B")
        }

        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        // A background pass has a hard budget and no user waiting.
        request.timeoutInterval = 20

        // Numbered with Gmail's requests so one console read counts every Google call.
        let seq = await GmailAPI.CallLog.shared.next()
        let started = Date()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await providerData(for: request)
        } catch {
            RealtimeLog.log("calendar api #\(seq): \(method) \(path) → transport error")
            throw Failure.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw Failure.transport("no HTTP response")
        }
        RealtimeLog.log("calendar api #\(seq): \(method) \(path) → \(http.statusCode) \(data.count)B in \(Int(Date().timeIntervalSince(started) * 1000))ms")
        switch http.statusCode {
        case 200..<300: break
        case 429:
            throw Failure.throttled
        case 403 where String(decoding: data, as: UTF8.self).contains("ateLimit"):
            throw Failure.throttled
        case 401, 403: throw Failure.unauthorized
        default: throw Failure.http(http.statusCode)
        }
        return data
    }
}
