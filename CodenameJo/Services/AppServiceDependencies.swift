import Foundation

protocol HTTPDataTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

struct URLSessionDataTransport: HTTPDataTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await URLSession.shared.data(for: request)
    }
}

protocol GoogleGrantStorage: Sendable {
    func all() -> [GoogleAccountStore.Grant]
    func save(_ grant: GoogleAccountStore.Grant) -> Bool
    func remove(_ email: String)
    func removeAll()
}

struct KeychainGrantStorage: GoogleGrantStorage {
    func all() -> [GoogleAccountStore.Grant] { KeychainGoogleGrantStore.all() }
    func save(_ grant: GoogleAccountStore.Grant) -> Bool { KeychainGoogleGrantStore.save(grant) }
    func remove(_ email: String) { KeychainGoogleGrantStore.remove(email) }
    func removeAll() { KeychainGoogleGrantStore.removeAll() }
}

@MainActor
protocol GoogleTokenProvider {
    func token(for email: String?, requiredScopes: [String]) async -> Result<GoogleCredential.Token, GoogleCredential.Failure>
}

@MainActor
struct KeychainTokenProvider: GoogleTokenProvider {
    func token(for email: String?, requiredScopes: [String]) async -> Result<GoogleCredential.Token, GoogleCredential.Failure> {
        await GoogleCredential.liveToken(for: email, requiredScopes: requiredScopes)
    }
}

protocol VoiceEvidence: Sendable {
    var runID: String? { get }
    func record(_ kind: String, _ fields: [String: Any])
    func receive(_ data: Data)
    func retainRecording(_ source: URL, completion: @escaping () -> Void)
}

extension VoiceEvidence {
    func record(_ kind: String) { record(kind, [:]) }
}

struct UnrecordedVoiceEvidence: VoiceEvidence {
    let runID: String? = nil
    func record(_ kind: String, _ fields: [String: Any]) {}
    func receive(_ data: Data) {}
    func retainRecording(_ source: URL, completion: @escaping () -> Void) { completion() }
}
