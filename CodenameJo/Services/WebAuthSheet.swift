import AuthenticationServices
import UIKit

/// All connector callbacks can arrive on a browser's XPC queue, including cancellation.
@MainActor
enum WebAuthSheet {
    private static var active: (id: UUID, session: ASWebAuthenticationSession, reply: WebAuthReply)?
    private static let anchor = Anchor()

    static func present(_ url: URL, callbackScheme: String) async throws -> URL {
        guard active == nil else { throw URLError(.resourceUnavailable) }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let reply = WebAuthReply { result in
                    active = nil
                    continuation.resume(with: result)
                }
                let session = ASWebAuthenticationSession(
                    url: url, callbackURLScheme: callbackScheme, completionHandler: reply.receive)
                session.presentationContextProvider = anchor
                session.prefersEphemeralWebBrowserSession = false
                active = (id, session, reply)
                if !session.start() { reply.finish(.failure(URLError(.cannotOpenFile))) }
            }
        } onCancel: {
            Task { @MainActor in
                guard let pending = active, pending.id == id else { return }
                pending.session.cancel()
                pending.reply.finish(.failure(CancellationError()))
            }
        }
    }

    private final class Anchor: NSObject, ASWebAuthenticationPresentationContextProviding {
        func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
            UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.keyWindow }
                .first ?? ASPresentationAnchor()
        }
    }
}

@MainActor
final class WebAuthReply {
    private var completion: ((Result<URL, Error>) -> Void)?

    init(_ completion: @escaping (Result<URL, Error>) -> Void) {
        self.completion = completion
    }

    nonisolated func receive(_ url: URL?, _ error: Error?) {
        Task { @MainActor in
            if let url { finish(.success(url)) }
            else { finish(.failure(error ?? URLError(.badServerResponse))) }
        }
    }

    func finish(_ result: Result<URL, Error>) {
        guard let completion else { return }
        self.completion = nil
        completion(result)
    }
}
