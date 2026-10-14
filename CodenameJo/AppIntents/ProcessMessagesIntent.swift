import AppIntents
import FactoryKit
import Foundation

/// A shortcut hands Jo the text of recent messages (Find Message → Combine Text) and gets
/// Jo's reply back. Runs in the background so an automation can chain it into Send Message.
@available(iOS 27, *)
struct ProcessMessagesIntent: AppIntent {
    static var title: LocalizedStringResource = "Process Messages"
    static var description = IntentDescription(
        "Reads recent message text and returns Codename Jo's reply. Feed it Find Message combined into one text.",
        categoryName: "Messaging"
    )
    static var isDiscoverable: Bool = false
    static var openAppWhenRun: Bool = false
    static var supportedModes: IntentModes = .background
    #if compiler(>=6.4)
    static var allowedExecutionTargets: IntentExecutionTargets = .main
    #endif
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @Parameter(title: "Messages") var transcript: String
    @Parameter(title: "Conversation") var conversation: String?
    @Parameter(title: "Instruction", default: "Reply to the latest message on my behalf.")
    var instruction: String

    private func unavailableReply() throws -> String {
        throw ProcessMessagesError.unavailable
    }

    @MainActor
    func perform() async throws -> some ReturnsValue<String> {
        // Unwired until the broker offers a reply-only route with no tools.
        let reply = try unavailableReply()
        return .result(value: reply)
        /*
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ProcessMessagesError.emptyInput }

        var task = instruction + "\n\nThese are the recent text messages"
        if let conversation, !conversation.isEmpty { task += " in the conversation with \(conversation)" }
        task += ". Write only the reply to send, as one short text message, with no preamble:\n\n" + text

        let outcome = try await performBackgroundTask {
            await DispatchWorker.run(DispatchWorker.Job(id: UUID(), task: task))
        }
        guard outcome.ok != false else { throw ProcessMessagesError.failed(outcome.text) }
        return .result(value: outcome.text)
        */

    }
}

#if compiler(>=6.4)
@available(iOS 27, *)
extension ProcessMessagesIntent: LongRunningIntent {}
#endif

enum ProcessMessagesError: LocalizedError, CustomLocalizedStringResourceConvertible {
    case unavailable
    case emptyInput
    case failed(String)

    var errorDescription: String? { String(localized: localizedStringResource) }

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .unavailable:
            "Process Messages is unavailable until Jo has a reply-only broker route. For a live read, use Give Messages to Jo instead."
        case .emptyInput:
            "No message text was supplied."
        case .failed(let message):
            "Jo could not process the messages: \(message)"
        }
    }
}
