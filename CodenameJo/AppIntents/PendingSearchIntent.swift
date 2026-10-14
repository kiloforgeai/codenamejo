import AppIntents
import FactoryKit
import Foundation

/// The requested contact name; no value means unread texts from anyone.
@available(iOS 27, *)
struct PendingSearchIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Jo Search Name"
    static var description = IntentDescription(
        "Returns the requested contact name, or nothing for unread texts from anyone. Use Get Jo Contact for Find Message's Sender filter.",
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
    func perform() async throws -> some ReturnsValue<String?> {
        let runner = Container.shared.shortcutActions()
        guard let id = UUID(uuidString: requestID), runner.matches(id) else {
            throw ShortcutRequestError.expired
        }
        // Nil, not "": Shortcuts' "has any value" is true for empty text, which would send
        // an everyone-unread request down the contact branch.
        let name = Container.shared.shortcutActions().pendingSearchName ?? ""
        return .result(value: name.isEmpty ? nil : name)
    }
}
