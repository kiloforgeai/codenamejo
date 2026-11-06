#if targetEnvironment(macCatalyst)
import Combine
import FactoryKit
import Foundation

@MainActor
class DesktopEmailReader: ObservableObject {
    struct Request: Hashable, Sendable {
        let selection: MailSelection
        let threadID: String?
        let ownerID: String
        let profileID: String?
        let conversationID: UUID?
        let headersOnly: Bool
    }

    struct Message: Equatable, Identifiable, Sendable {
        let id: String
        let from: String
        let to: String
        let cc: String
        let subject: String
        let date: String
        let body: AttributedString
        var text: String { String(body.characters) }
        let attachments: [String]
        let error: String?
    }

    struct Content: Equatable, Sendable {
        let selectedID: String
        let messages: [Message]
    }

    enum State: Equatable {
        case idle
        case loading(Request)
        case ready(Request, Content)
        case failed(Request, String)
        case headersOnly(Request)

        var request: Request? {
            switch self {
            case .idle: return nil
            case .loading(let request), .ready(let request, _), .failed(let request, _), .headersOnly(let request):
                return request
            }
        }
    }

    typealias Loader = @Sendable (Request) async throws -> Content
    @Published var state: State = .idle
    private let loader: Loader
    private let allowed: (Request) -> Bool
    private var task: Task<Void, Never>?
    private var generation = 0

    init(loader: @escaping Loader = { try await DesktopEmailReader.load($0) },
         allowed: @escaping (Request) -> Bool = DesktopEmailReader.isAllowed) {
        self.loader = loader
        self.allowed = allowed
    }

    func show(_ request: Request?, retry: Bool = false) {
        if let request, !allowed(request) {
            generation += 1
            task?.cancel()
            task = nil
            state = .failed(request, "This mailbox is no longer available in the active profile. Check its connection in Settings.")
            return
        }
        guard retry || state.request != request else { return }
        generation += 1
        let generation = generation
        task?.cancel()
        task = nil
        guard let request else { state = .idle; return }
        guard !request.headersOnly else { state = .headersOnly(request); return }
        if !retry, case .ready(let previous, let content) = state,
           previous.selection == request.selection, previous.threadID == request.threadID,
           previous.ownerID == request.ownerID, previous.profileID == request.profileID,
           previous.headersOnly == request.headersOnly {
            state = .ready(request, content)
            return
        }
        state = .loading(request)
        task = Task { [weak self, loader] in
            do {
                let content = try await loader(request)
                guard let self, !Task.isCancelled, self.generation == generation else { return }
                guard self.allowed(request) else { self.state = .idle; return }
                self.state = .ready(request, content)
            } catch {
                guard let self, !Task.isCancelled, self.generation == generation else { return }
                guard self.allowed(request) else { self.state = .idle; return }
                self.state = .failed(request, error.localizedDescription)
            }
        }
    }

    static func isAllowed(_ request: Request) -> Bool {
        Container.shared.backend().userId == request.ownerID
            && ProfileRuntime.snapshot?.profileId == request.profileID
            && MailHeadersOnly.withholdsBodies == request.headersOnly
            && ProfileRuntime.allowedMailAccounts(GoogleAccountStore.mailAccounts()).contains {
                $0.caseInsensitiveCompare(request.selection.account) == .orderedSame
            }
    }

    nonisolated private static func load(_ request: Request) async throws -> Content {
        guard !request.headersOnly, await isAllowed(request) else { throw CancellationError() }
        let token: String
        switch await GoogleCredential.token(for: request.selection.account) {
        case .success(let credential):
            guard credential.email?.caseInsensitiveCompare(request.selection.account) == .orderedSame else {
                throw FullEmailSource.Failure(message: "The connected mailbox changed. Select this email again.")
            }
            token = credential.accessToken
        case .failure(.noStoredGrant), .failure(.grantRevoked), .failure(.scopesMissing):
            throw FullEmailSource.Failure(message: "Reconnect this Google account in Settings to read the email.")
        case .failure(.transient):
            throw FullEmailSource.Failure(message: "The mailbox could not be reached. Check your connection and retry.")
        }
        try Task.checkCancellation()
        guard await isAllowed(request) else { throw CancellationError() }
        let threadID: String
        if let known = request.threadID, !known.isEmpty { threadID = known }
        else {
            let message = try await GmailAPI.fullMessage(token: token, id: request.selection.messageID)
            guard message.id == request.selection.messageID else {
                throw FullEmailSource.Failure(message: "Google returned a different email. Select this email again.")
            }
            threadID = message.threadId
        }
        try Task.checkCancellation()
        guard await isAllowed(request) else { throw CancellationError() }
        let thread = try await GmailAPI.fullThread(token: token, id: threadID)
        return try await decode(thread, request: request) { messageID, attachmentID in
            guard await isAllowed(request) else { throw CancellationError() }
            return try await GmailAPI.attachment(token: token, messageId: messageID, attachmentId: attachmentID)
        }
    }

    nonisolated static func decode(_ thread: GmailAPI.FullThread, request: Request,
                                   attachment: (String, String) async throws -> Data) async throws -> Content {
        try Task.checkCancellation()
        guard let threadID = thread.id, request.threadID == nil || request.threadID == threadID,
              let source = thread.messages, !source.isEmpty,
              source.contains(where: { $0.id == request.selection.messageID }),
              source.allSatisfy({ $0.threadId == threadID }), Set(source.map(\.id)).count == source.count else {
            throw FullEmailSource.Failure(message: "Google did not return the selected email's complete thread. Please retry.")
        }
        var messages: [Message] = []
        var bytes = 0
        let ordered = source.enumerated().sorted {
            (Int64($0.element.internalDate ?? "") ?? 0, $0.offset)
                < (Int64($1.element.internalDate ?? "") ?? 0, $1.offset)
        }.map(\.element)
        for message in ordered {
            try Task.checkCancellation()
            var body = AttributedString(), failure: String?
            do {
                let text = try await FullEmailSource.read(
                    selection: .init(account: request.selection.account, messageID: message.id),
                    threadID: threadID, prepared: nil, fetch: { message },
                    attachment: { try await attachment(message.id, $0) }).text
                bytes += text.utf8.count
                body = try linkedBody(text)
            } catch is CancellationError { throw CancellationError() }
            catch { failure = error.localizedDescription }
            guard bytes <= 24_000_000 else {
                throw FullEmailSource.Failure(message: "This thread is too large to display here. Open it in Gmail to read every message.")
            }
            messages.append(Message(id: message.id, from: message.header("From") ?? "Unknown sender",
                to: message.header("To") ?? "", cc: message.header("Cc") ?? "",
                subject: message.header("Subject") ?? "No subject", date: message.header("Date") ?? "",
                body: body, attachments: GmailReadTools.attachments(in: message.payload).map(\.filename), error: failure))
        }
        return Content(selectedID: request.selection.messageID, messages: messages)
    }

    nonisolated static func linkedBody(_ text: String) throws -> AttributedString {
        var body = AttributedString(text)
        let detector = try NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let url = match.url, let scheme = url.scheme?.lowercased(),
                  ["http", "https", "mailto"].contains(scheme),
                  let range = Range(match.range, in: text),
                  let start = AttributedString.Index(range.lowerBound, within: body),
                  let end = AttributedString.Index(range.upperBound, within: body) else { continue }
            body[start..<end].link = url
        }
        return body
    }
}
#endif
