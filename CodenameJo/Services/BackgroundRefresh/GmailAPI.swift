import Foundation
import FactoryKit

/// Gmail's REST API, called from the phone with the phone's own grant; no broker is involved.
enum GmailAPI {
    private static func providerData(for request: URLRequest) async throws -> (Data, URLResponse) {
        return try await Container.shared.providerHTTP().data(for: request)

    }

    private static let base = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me")!

    /// Headers worth storing; `format=metadata` returns these instead of the payload.
    private static let metadataHeaders = ["From", "To", "Subject", "Date", "Message-ID", "In-Reply-To", "References", "List-Unsubscribe"]

    enum Failure: Error {
        /// `startHistoryId` is older than Gmail's ~1-week history window, so a full resync is owed.
        /// Expected after a device is off a while; not an error to surface.
        case historyExpired
        /// The token was rejected. Usually a revoked grant; the caller re-reads the
        /// credential rather than retrying the request.
        case unauthorized
        /// Rate refusal: wait and retry. Unlike `unauthorized`, which must not be retried.
        case throttled
        case http(Int)
        case transport(String)
        case decoding(String)
    }

    // MARK: - Shapes

    struct MessageRef: Decodable {
        let id: String
        let threadId: String
    }

    struct MessageList: Decodable {
        let messages: [MessageRef]?
        let nextPageToken: String?
    }

    struct MessageDetail: Decodable {
        let id: String
        let threadId: String
        let labelIds: [String]?
        let snippet: String?
        /// Milliseconds since epoch; Gmail returns int64 fields as JSON strings.
        let internalDate: String?
        let payload: Payload?

        struct Payload: Decodable {
            let headers: [Header]?
        }

        struct Header: Codable {
            let name: String
            let value: String
        }

        func header(_ name: String) -> String? {
            payload?.headers?.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
    }

    struct Profile: Decodable {
        let emailAddress: String?
        let historyId: String?
    }

    /// `format=full`: the MIME tree with bodies, for the writing-style scan. Every other
    /// caller here wants headers only and pays a fifth of the bytes.
    struct FullMessage: Codable {
        var snippet: String? = nil
        let id: String
        let threadId: String
        let labelIds: [String]?
        let internalDate: String?
        let payload: FullPart?

        func header(_ name: String) -> String? {
            payload?.headers?.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
    }

    struct FullPart: Codable {
        let mimeType: String?
        let filename: String?
        let headers: [MessageDetail.Header]?
        let body: PartBody?
        let parts: [FullPart]?
    }

    struct PartBody: Codable {
        let size: Int?
        /// Base64url, as Gmail encodes it.
        let data: String?
        /// Set on a file part whose bytes sit behind `attachment(token:messageId:attachmentId:)`.
        var attachmentId: String? = nil
    }

    struct FullThread: Decodable {
        let id: String?
        let messages: [FullMessage]?
    }

    static func fullMessage(token: String, id: String) async throws -> FullMessage {
        await GmailQuota.shared.spend(GmailQuota.Cost.get)
        return try await get(
            path: "messages/\(id)",
            query: ["format": "full", "fields": "id,threadId,labelIds,snippet,internalDate,payload"],
            token: token
        )
    }

    static func fullThread(token: String, id: String) async throws -> FullThread {
        await GmailQuota.shared.spend(10)
        return try await get(path: "threads/\(id)", query: ["format": "full"], token: token)
    }

    /// One attachment's bytes. A body fetch, so refused when bodies are withheld.
    static func attachment(token: String, messageId: String, attachmentId: String) async throws -> Data {
        guard !MailHeadersOnly.withholdsBodies else { throw HeadersOnly() }
        await GmailQuota.shared.spend(GmailQuota.Cost.get)
        struct Body: Decodable { let data: String? }
        let body: Body = try await get(
            path: "messages/\(messageId)/attachments/\(attachmentId)", query: [:], token: token)
        return body.data.flatMap(decodeBase64URL) ?? Data()
    }

    static func decodeBase64URL(_ value: String) -> Data? {
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        return Data(base64Encoded: base64)
    }

    /// One entry in `drafts.list` — the draft's own id plus a bare reference to the message
    /// it wraps. No headers or snippet here; those come from `draftDetail`.
    struct DraftRef: Decodable {
        let id: String
        let message: MessageRef?
    }

    struct DraftList: Decodable {
        let drafts: [DraftRef]?
        let nextPageToken: String?
    }

    /// `drafts.get`'s shape: the draft id wrapping a full `Message` resource, so its headers
    /// and snippet decode with the same `MessageDetail` a message read already uses.
    struct DraftDetail: Decodable {
        let id: String
        let message: MessageDetail?
    }

    // MARK: - Calls

    /// The account's address and its current `historyId` — the baseline a later delta
    /// counts from. One call, 1 quota unit.
    static func profile(token: String) async throws -> Profile {
        try await get(path: "profile", query: [:], token: token)
    }

    /// How many unread messages the inbox holds, off Gmail's own counter.
    ///
    /// `users.labels.get` on `INBOX` carries `messagesUnread`: one quota unit, exact, and uncapped
    /// where a listing stops at "more than 500".
    static func inboxUnreadCount(token: String) async throws -> Int {
        await GmailQuota.shared.spend(GmailQuota.Cost.profile)
        struct Label: Decodable { let messagesUnread: Int? }
        let label: Label = try await get(
            path: "labels/INBOX", query: ["fields": "messagesUnread"], token: token
        )
        return label.messagesUnread ?? 0
    }

    /// How many messages the inbox holds in total, read and unread.
    ///
    /// Off the same label as `inboxUnreadCount`; a listing would cap at "more than 500".
    static func inboxTotalCount(token: String) async throws -> Int {
        await GmailQuota.shared.spend(GmailQuota.Cost.profile)
        struct Label: Decodable { let messagesTotal: Int? }
        let label: Label = try await get(
            path: "labels/INBOX", query: ["fields": "messagesTotal"], token: token
        )
        return label.messagesTotal ?? 0
    }

    /// Recent message ids. `messages.list` is 5 units and returns ids only, which is why
    /// the metadata fetch below is a separate step rather than a richer version of this.
    static func recentMessageIds(
        token: String, query: String, limit: Int
    ) async throws -> [MessageRef] {
        try await messagePage(token: token, query: query, limit: limit).messages ?? []
    }

    /// One page of ids, with the token for the next.
    ///
    /// An empty `query` means the whole mailbox, not just the inbox, with no date bound.
    static func messagePage(
        token: String, query: String, limit: Int, pageToken: String? = nil
    ) async throws -> MessageList {
        var params = [
            "maxResults": String(limit),
            "fields": "messages/id,messages/threadId,nextPageToken",
        ]
        if !query.isEmpty { params["q"] = query }
        if let pageToken { params["pageToken"] = pageToken }
        return try await get(path: "messages", query: params, token: token)
    }

    /// Metadata for one message.
    struct ThreadInboxState: Decodable {
        struct Message: Decodable { let labelIds: [String]? }
        /// Required, so a batched reply matches its thread and a refused sub-request (a 200 with
        /// no id) fails to decode instead of reading as a thread with no inbox member.
        let id: String
        let messages: [Message]?

        var isInInbox: Bool {
            messages?.contains { $0.labelIds?.contains("INBOX") == true } == true
        }
    }

    /// A failed read is unknown, so only confirmed absent threads are returned.
    /// One multipart round trip rather than a `threads.get` per thread.
    static func archivedThreadIDs(token: String, ids: [String]) async -> Set<String> {
        let unique = Array(Set(ids))
        guard !unique.isEmpty else { return [] }
        var states: [ThreadInboxState] = []
        // Gmail refuses a batch over 100 sub-requests, so a long queue goes in runs.
        for start in stride(from: 0, to: unique.count, by: 50) {
            let run = Array(unique[start..<min(start + 50, unique.count)])
            states += await batch(
                token: token,
                paths: run.map { "threads/\($0)?format=minimal&fields=id,messages/labelIds" },
                seed: run[0], label: "threads.get")
        }
        // A thread missing from the reply was refused or unparsed, and unknown is not absent.
        if states.count != unique.count {
            RealtimeLog.log("localTriage: inbox verification unavailable for "
                + "\(unique.count - states.count) of \(unique.count) thread(s)")
        }
        return Set(states.filter { !$0.isInInbox }.map(\.id))
    }

    static func removedMessageIDs(token: String, ids: [String], label: String) async -> Set<String> {
        let unique = Array(Set(ids))
        var confirmed = Set<String>()
        for start in stride(from: 0, to: unique.count, by: 50) {
            let run = Array(unique[start..<min(start + 50, unique.count)])
            let states: [MessageDetail] = await batch(token: token,
                paths: run.map { "messages/\($0)?format=minimal&fields=id,threadId,labelIds" },
                seed: run[0], label: "messages.get")
            confirmed.formUnion(states.filter {
                $0.labelIds?.contains(label) == true && $0.labelIds?.contains("INBOX") == false
            }.map(\.id))
        }
        return confirmed
    }

    static func metadata(token: String, id: String) async throws -> MessageDetail {
        await GmailQuota.shared.spend(GmailQuota.Cost.get)
        // `metadataHeaders` must be repeated: a comma-joined value silently returns only the first header.
        return try await get(
            path: "messages/\(id)",
            query: [
                "format": "metadata",
                "fields": "id,threadId,labelIds,snippet,internalDate,payload/headers",
            ],
            repeated: metadataHeaders.map { ("metadataHeaders", $0) },
            token: token
        )
    }

    struct ThreadMetadata: Decodable {
        let id: String
        let messages: [MessageDetail]?
    }

    static func threadMetadata(token: String, id: String) async throws -> ThreadMetadata {
        await Container.shared.gmailQuota().spend(10)
        return try await get(path: "threads/\(id)",
            query: ["format": "metadata", "fields": "id,messages(id,threadId,labelIds,snippet,internalDate,payload/headers)"],
            repeated: metadataHeaders.map { ("metadataHeaders", $0) }, token: token)
    }

    /// Whether this message exposes an authenticated unsubscribe route Jo can safely use.
    static func hasSafeUnsubscribeRoute(token: String, id: String) async throws -> Bool {
        await GmailQuota.shared.spend(GmailQuota.Cost.get)
        let names = ["List-Unsubscribe", "List-Unsubscribe-Post", "Authentication-Results"]
        let detail: MessageDetail = try await get(
            path: "messages/\(id)",
            query: [
                "format": "metadata",
                "fields": "id,threadId,payload/headers",
            ],
            repeated: names.map { ("metadataHeaders", $0) },
            token: token
        )
        let routes = detail.header("List-Unsubscribe") ?? ""
        let post = detail.header("List-Unsubscribe-Post") ?? ""
        let authentication = detail.header("Authentication-Results") ?? ""
        let signed = authentication.range(
            of: #"\bdkim\s*=\s*pass\b"#,
            options: [.regularExpression, .caseInsensitive]) != nil
        let oneClick = post.range(
            of: #"\blist-unsubscribe\s*=\s*one-click\b"#,
            options: [.regularExpression, .caseInsensitive]) != nil
            && routes.range(of: #"<https://[^>]+>"#, options: [.regularExpression, .caseInsensitive]) != nil
        let mailto = routes.range(
            of: #"<mailto:[^>]+>"#,
            options: [.regularExpression, .caseInsensitive]) != nil
        return signed && (oneClick || mailto)
    }

    /// Metadata for up to 100 messages in one `multipart/mixed` request. Replies split on the boundary
    /// Google returns in `Content-Type`, never an assumed one; failed sub-requests are dropped.
    static func metadataBatch(token: String, ids: [String]) async -> [MessageDetail] {
        guard !ids.isEmpty else { return [] }
        // Before the request, not after: fifty gets is the whole per-second ceiling.
        await GmailQuota.shared.spendBatch(of: ids.count)
        let headerQuery = metadataHeaders.map { "&metadataHeaders=\($0)" }.joined()
        // Builds its query without `get`, so it repeats `get`'s snippet rule. Keep the two in step.
        let fields = MailHeadersOnly.withholdsBodies
            ? "id,threadId,labelIds,internalDate,payload/headers"
            : "id,threadId,labelIds,snippet,internalDate,payload/headers"
        return await batch(
            token: token,
            paths: ids.map { "messages/\($0)?format=metadata&fields=\(fields)" + headerQuery },
            seed: ids.first ?? "x", label: "messages.get")
    }

    /// Send a list of relative Gmail GET paths as one `multipart/mixed` request.
    ///
    /// Order is not guaranteed, so a caller that must tell the answers apart has to ask for a
    /// field that identifies them.
    private static func batch<T: Decodable>(
        token: String, paths: [String], seed: String, label: String
    ) async -> [T] {
        let boundary = "batch_aurex_\(paths.count)_\(seed)"
        var body = ""
        for (index, path) in paths.enumerated() {
            body += "--\(boundary)\r\n"
            body += "Content-Type: application/http\r\n"
            body += "Content-ID: <item\(index)>\r\n\r\n"
            body += "GET /gmail/v1/users/me/\(path)\r\n\r\n"
        }
        body += "--\(boundary)--\r\n"

        var request = URLRequest(url: URL(string: "https://gmail.googleapis.com/batch/gmail/v1")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/mixed; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body.data(using: .utf8)
        request.timeoutInterval = 60

        let logLabel = "BATCH \(paths.count)\u{00D7} \(label)"
        let seq = await CallLog.shared.next()
        let started = Date()
        do {
            let (data, response) = try await providerData(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                logCall(logLabel, seq: seq, status: "\((response as? HTTPURLResponse)?.statusCode ?? 0)", started: started)
                return []
            }
            let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
            guard let replyBoundary = boundaryValue(in: contentType) else { return [] }
            let parts: [T] = decodeParts(String(decoding: data, as: UTF8.self), boundary: replyBoundary)
            logCall(logLabel, seq: seq, status: "\(http.statusCode) \(parts.count) of \(paths.count) \(data.count)B", started: started)
            return parts
        } catch {
            logCall(logLabel, seq: seq, status: "transport error", started: started)
            return []
        }
    }

    /// Pull `boundary=…` out of a `Content-Type`, quoted or not.
    private static func boundaryValue(in contentType: String) -> String? {
        guard let range = contentType.range(of: "boundary=") else { return nil }
        let raw = contentType[range.upperBound...]
        let value = raw.prefix { $0 != ";" && !$0.isWhitespace }
        return value.isEmpty ? nil : String(value).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    /// Each part is an embedded HTTP response whose JSON starts at the first `{`. A refused
    /// sub-request is a JSON error envelope, logged rather than silently dropped.
    private static func decodeParts<T: Decodable>(_ text: String, boundary: String) -> [T] {
        var failures: [String] = []
        let details = text.components(separatedBy: "--\(boundary)").compactMap { part -> T? in
            guard let start = part.firstIndex(of: "{"),
                  let end = part.lastIndex(of: "}"), start < end
            else { return nil }
            let json = String(part[start...end])
            if let detail = try? JSONDecoder().decode(T.self, from: Data(json.utf8)) {
                return detail
            }
            if let error = try? JSONDecoder().decode(BatchError.self, from: Data(json.utf8)) {
                failures.append("\(error.error.code) \(error.error.status ?? "")")
            } else {
                failures.append("unparsed")
            }
            return nil
        }
        if !failures.isEmpty {
            // Counted by reason rather than listed: fifty identical 429s is one fact.
            let tally = Dictionary(grouping: failures, by: { $0 })
                .map { "\($0.value.count)×\($0.key)" }
                .joined(separator: ", ")
            RealtimeLog.log("gmail: batch sub-request failures — \(tally)")
        }
        return details
    }

    /// What Gmail returns for a sub-request it refused.
    private struct BatchError: Decodable {
        struct Detail: Decodable {
            let code: Int
            let status: String?
        }
        let error: Detail
    }

    /// Metadata for many messages, six at a time: an unbounded group draws 429s.
    /// A failed message is dropped, not thrown, so one miss doesn't discard the pass.
    static func metadata(
        token: String, ids: [String], concurrency: Int = 6
    ) async -> [MessageDetail] {
        var results: [MessageDetail] = []
        var index = 0

        while index < ids.count {
            let slice = ids[index..<min(index + concurrency, ids.count)]
            index += slice.count

            await withTaskGroup(of: MessageDetail?.self) { group in
                for id in slice {
                    group.addTask { try? await metadata(token: token, id: id) }
                }
                for await detail in group {
                    if let detail { results.append(detail) }
                }
            }
        }
        return results
    }

    /// One page of the mailbox's drafts. `query` follows the same `q=` syntax
    /// `messagePage` takes; empty means every draft.
    static func draftPage(
        token: String, query: String = "", limit: Int, pageToken: String? = nil
    ) async throws -> DraftList {
        var params = [
            "maxResults": String(limit),
            "fields": "drafts/id,drafts/message/id,drafts/message/threadId,nextPageToken",
        ]
        if !query.isEmpty { params["q"] = query }
        if let pageToken { params["pageToken"] = pageToken }
        return try await get(path: "drafts", query: params, token: token)
    }

    /// One draft's metadata — headers and snippet for the message it wraps, no body.
    static func draftDetail(token: String, id: String) async throws -> DraftDetail {
        await GmailQuota.shared.spend(GmailQuota.Cost.get)
        return try await get(
            path: "drafts/\(id)",
            query: [
                "format": "metadata",
                "fields": "id,message(id,threadId,labelIds,snippet,internalDate,payload/headers)",
            ],
            repeated: metadataHeaders.map { ("metadataHeaders", $0) },
            token: token
        )
    }

    /// Clear the `UNREAD` label. `messages.modify` is 5 quota units, the same as a get.
    static func markRead(token: String, id: String) async throws {
        await GmailQuota.shared.spend(GmailQuota.Cost.get)
        try await post(
            path: "messages/\(id)/modify",
            body: ["removeLabelIds": ["UNREAD"]],
            token: token
        )
    }

    /// Take a message out of the inbox. `UNREAD` comes off with `INBOX`, as the broker's archive does.
    static func archive(token: String, id: String) async throws {
        await GmailQuota.shared.spend(GmailQuota.Cost.get)
        try await post(
            path: "messages/\(id)/modify",
            body: ["removeLabelIds": ["INBOX", "UNREAD"]],
            token: token
        )
    }

    /// Any call the mail-management tools make, answered as its JSON object (an empty 2xx body is `{}`).
    /// Gmail refuses a duplicate filter with a 400; that one is reported as the 409 a label clash gets.
    static func call(_ method: String, path: String, query: [String: String] = [:], repeated: [(String, String)] = [],
                     body: [String: Any]? = nil, token: String) async throws -> [String: Any] {
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        let items = query.map { URLQueryItem(name: $0.key, value: $0.value) } + repeated.map { URLQueryItem(name: $0.0, value: $0.1) }
        if !items.isEmpty { components.queryItems = items }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        request.timeoutInterval = 20
        let label = describe(method, path, components.queryItems ?? [])
        let seq = await CallLog.shared.next()
        let started = Date()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await providerData(for: request)
        } catch {
            logCall(label, seq: seq, status: "transport error", started: started)
            throw Failure.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw Failure.transport("no HTTP response") }
        logCall(label, seq: seq, status: "\(http.statusCode) \(data.count)B", started: started)
        let text = String(decoding: data, as: UTF8.self)
        switch http.statusCode {
        case 200..<300: break
        case 429: throw Failure.throttled
        case 403 where text.contains("ateLimit"): throw Failure.throttled
        case 401, 403: throw Failure.unauthorized
        case 400 where text.contains("Filter already exists"): throw Failure.http(409)
        default: throw Failure.http(http.statusCode)
        }
        guard !data.isEmpty else { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.decoding("\(path) — \(text.prefix(200))")
        }
        return object
    }

    // MARK: - Transport

    /// The phone asked Gmail for something it may not have on this account.
    /// Only reachable through a programming error; every body fetch is gated before `get`.
    struct HeadersOnly: Error {}

    /// One line per Gmail HTTP request, numbered per launch, so a console read counts them.
    actor CallLog {
        static let shared = CallLog()
        private var count = 0
        func next() -> Int { count += 1; return count }
    }

    /// `messages?q=in:inbox is:unread max=100`, without the token or the field masks.
    private static func describe(_ method: String, _ path: String, _ items: [URLQueryItem]) -> String {
        var line = "\(method) \(path)"
        if let q = items.first(where: { $0.name == "q" })?.value { line += " q=\(q)" }
        if let max = items.first(where: { $0.name == "maxResults" })?.value { line += " max=\(max)" }
        return line
    }

    private static func logCall(_ label: String, seq: Int, status: String, started: Date) {
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        RealtimeLog.log("gmail api #\(seq): \(label) → \(status) in \(ms)ms")
    }

    private static func get<T: Decodable>(
        path: String,
        query: [String: String],
        repeated: [(String, String)] = [],
        token: String
    ) async throws -> T {
        // The phone holds its own grant, so bodies are withheld here too. `snippet` is the body's
        // first 200 characters, so it goes with them.
        var query = query
        if MailHeadersOnly.withholdsBodies {
            guard query["format"] != "full" else { throw HeadersOnly() }
            if let fields = query["fields"], fields.contains("snippet") {
                query["fields"] = fields
                    .split(separator: ",")
                    .filter { !$0.contains("snippet") }
                    .joined(separator: ",")
            }
        }
        var components = URLComponents(
            url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false
        )!
        var items = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        items.append(contentsOf: repeated.map { URLQueryItem(name: $0.0, value: $0.1) })
        components.queryItems = items

        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // URLSession negotiates gzip itself; this names the requirement so it isn't tidied away.
        request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
        // A hung request would spend a background pass's whole budget.
        request.timeoutInterval = 20

        let label = describe("GET", path, items)
        let seq = await CallLog.shared.next()
        let started = Date()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await providerData(for: request)
        } catch {
            logCall(label, seq: seq, status: "transport error", started: started)
            throw Failure.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw Failure.transport("no HTTP response")
        }
        logCall(label, seq: seq, status: "\(http.statusCode) \(data.count)B", started: started)
        switch http.statusCode {
        case 200..<300: break
        // Gmail answers a per-user rate limit with `403 rateLimitExceeded` as often as 429;
        // reading it as a bad token would surface a needless reconnect.
        case 429:
            throw Failure.throttled
        case 403 where String(decoding: data, as: UTF8.self).contains("ateLimit"):
            throw Failure.throttled
        case 401, 403: throw Failure.unauthorized
        default: throw Failure.http(http.statusCode)
        }

        // With a `fields` mask and no matches, `messages.list` returns zero bytes rather than `{}`.
        // Every field on these shapes is optional, so `{}` decodes as an empty result.
        let body = data.isEmpty ? Data("{}".utf8) : data
        do {
            return try JSONDecoder().decode(T.self, from: body)
        } catch {
            // Names the path and the body's first bytes: Gmail answers some refusals with 200 and an error envelope.
            let head = String(decoding: data.prefix(200), as: UTF8.self)
                .replacingOccurrences(of: "\n", with: " ")
            throw Failure.decoding("\(path) — \(head)")
        }
    }

    /// A write. Same refusal handling as `get`: a 403 naming a rate limit is a throttle.
    private static func post(
        path: String, body: [String: Any], token: String
    ) async throws {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 20

        let label = describe("POST", path, [])
        let seq = await CallLog.shared.next()
        let started = Date()
        let response: URLResponse
        let data: Data
        do {
            (data, response) = try await providerData(for: request)
        } catch {
            logCall(label, seq: seq, status: "transport error", started: started)
            throw Failure.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw Failure.transport("no HTTP response")
        }
        logCall(label, seq: seq, status: "\(http.statusCode)", started: started)
        switch http.statusCode {
        case 200..<300: return
        case 429: throw Failure.throttled
        case 403 where String(decoding: data, as: UTF8.self).contains("ateLimit"):
            throw Failure.throttled
        case 401, 403: throw Failure.unauthorized
        default: throw Failure.http(http.statusCode)
        }
    }
}
