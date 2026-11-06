import Combine
import FactoryKit
import Foundation

enum FeedbackSource: String, Sendable { case voice, button }

struct FeedbackContext: Sendable {
    var sessionID: UUID?
    var conversationID: UUID?
    var profileID: String?
    var engine = "idle"
    var state = "ready"
    var renderRevision: Int? = nil
}

enum FeedbackError: LocalizedError {
    case empty, tooLong, signedOut, accountChanged, invalidArguments

    var errorDescription: String? {
        switch self {
        case .empty: return "Add a few words about what happened."
        case .tooLong: return "Keep feedback under \(FeedbackText.maximumCharacters + 1) characters."
        case .signedOut: return "Sign in before saving feedback."
        case .accountChanged: return "Your account changed. Close this note and open Feedback again."
        case .invalidArguments: return "Feedback needs a message containing the user's own feedback."
        }
    }
}

enum FeedbackText {
    static let maximumCharacters = 4_000

    static func validated(_ text: String) throws -> String {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { throw FeedbackError.empty }
        guard message.count <= maximumCharacters else { throw FeedbackError.tooLong }
        return message
    }
}

@MainActor
class UserFeedback: ObservableObject {
    struct Submission {
        let userID: String?
        let context: FeedbackContext
    }

    @Injected(\.backend) private var backend
    @Injected(\.realtimeService) private var realtime
    @Injected(\.voiceDiagnostics) private var diagnostics

    func capture() -> Submission { Submission(userID: backend.userId, context: realtime.feedbackContext) }

    func save(_ message: String, source: FeedbackSource, submission: Submission) async throws -> UUID {
        guard let userID = submission.userID else { throw FeedbackError.signedOut }
        guard userID == backend.userId else { throw FeedbackError.accountChanged }
        return try await diagnostics.saveFeedback(message, source: source, userID: userID, context: submission.context)
    }
}

enum UserFeedbackTool {
    static let name = "log_feedback"

    @MainActor
    static func run(argumentsJSON: String, save: (String) async throws -> UUID) async -> (output: String, failed: Bool) {
        do {
            let object = try JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))
            guard let args = object as? [String: Any], let message = args["message"] as? String else {
                throw FeedbackError.invalidArguments
            }
            let id = try await save(FeedbackText.validated(message))
            return ("Feedback saved locally in Jo's logs. Reference: \(id.uuidString). "
                + "Acknowledge briefly; do not read the reference aloud. Nothing was uploaded and no issue was filed. "
                + "Keep the current task selected; this does not advance the feed.", false)
        } catch {
            return ("Feedback was NOT saved: \(error.localizedDescription)", true)
        }
    }
}
