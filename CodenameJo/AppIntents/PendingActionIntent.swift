import AppIntents
import FactoryKit
import Foundation

/// The branch to run after Get Jo Request ID has claimed a messaging request.
@available(iOS 27, *)
struct PendingActionIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Jo Request"
    static var description = IntentDescription(
        "Returns read, unread, or send for the matching Jo Messages request.",
        categoryName: "Messaging"
    )
    static var openAppWhenRun: Bool = false
    static var supportedModes: IntentModes = .background
    #if compiler(>=6.4)
    static var allowedExecutionTargets: IntentExecutionTargets = .main
    #endif
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @Parameter(title: "Request ID") var requestID: String

    @MainActor
    func perform() async throws -> some ReturnsValue<String> {
        let runner = Container.shared.shortcutActions()
        guard let id = UUID(uuidString: requestID), runner.matches(id) else {
            throw ShortcutRequestError.expired
        }
        let action = Container.shared.shortcutActions().pendingAction ?? ""
        // Which branch the shortcut takes; the read and unread paths filter differently.
        RealtimeLog.log("shortcuts: Get Jo Request answered \"\(action)\"")
        return .result(value: action)
    }
}
