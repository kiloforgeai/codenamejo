import AppIntents
import FactoryKit
import Foundation

/// Returns messages to the live call using its original Request ID.
@available(iOS 27, *)
struct DeliverMessagesIntent: AppIntent {
    static var title: LocalizedStringResource = "Give Messages to Jo"
    static var description = IntentDescription(
        "Returns unread messages to Codename Jo. Set Messages to Repeat Results, one \"Sender: Body\" text per message found.",
        categoryName: "Messaging"
    )
    static var openAppWhenRun: Bool = false
    static var supportedModes: IntentModes = .background
    // Jo is already running with the call; never spend a launch on an extension.
    #if compiler(>=6.4)
    static var allowedExecutionTargets: IntentExecutionTargets = .main
    #endif
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    // Text, not a list: the Shortcuts editor drops a variable bound to a list field.
    @Parameter(title: "Messages") var messages: String?

    @Parameter(title: "Request ID") var requestID: String

    @MainActor
    func perform() async throws -> some IntentResult {
        let runner = Container.shared.shortcutActions()
        guard let id = UUID(uuidString: requestID), runner.matches(id) else {
            throw ShortcutRequestError.expired
        }
        // Repeat Results arrive joined by newlines; a body may contain its own, so pass it whole.
        let text = ShortcutMessageExcerpt.bound(messages ?? "")
        RealtimeLog.log("shortcuts: Give Messages to Jo received \(text.count) chars")
        #if DEBUG
        // Debug builds only: message text never reaches a release log.
        RealtimeLog.log("shortcuts: Give Messages to Jo text:\n\(text)")
        #endif
        do {
            // Guard only: a contact read, if one ever arrives, cannot verify its sender from text.
            try runner.validateReadSenders([], bodyCount: text.isEmpty ? 0 : 1, transcript: nil, requestID: id)
        } catch {
            runner.fail(error.localizedDescription, requestID: id)
            throw error
        }
        guard runner.deliverMessages(text, requestID: id) else {
            throw ShortcutRequestError.expired
        }
        return .result()
    }
}
