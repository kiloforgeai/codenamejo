import AppIntents
import FactoryKit
import Foundation

/// Claims one request before the shortcut reads any of its fields.
@available(iOS 27, *)
struct ShortcutRequestIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Jo Request ID"
    static var description = IntentDescription("Start Jo Messages with this action. Use its result as Request ID in every following Jo action.")
    static var openAppWhenRun: Bool = false
    static var supportedModes: IntentModes = .background
    #if compiler(>=6.4)
    static var allowedExecutionTargets: IntentExecutionTargets = .main
    #endif
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @MainActor
    func perform() async throws -> some ReturnsValue<String> {
        guard let id = Container.shared.shortcutActions().claimRequest() else {
            throw ShortcutRequestError.expired
        }
        return .result(value: id.uuidString)
    }
}

/// Goes immediately after Send Message, using the ID captured at the start.
@available(iOS 27, *)
struct CompleteTextIntent: AppIntent {
    static var title: LocalizedStringResource = "Complete Jo Send"
    static var description = IntentDescription("Run only after Send Message finishes successfully. Pass the original Jo Request ID.")
    static var openAppWhenRun: Bool = false
    static var supportedModes: IntentModes = .background
    #if compiler(>=6.4)
    static var allowedExecutionTargets: IntentExecutionTargets = .main
    #endif
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @Parameter(title: "Request ID") var requestID: String

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: requestID),
              Container.shared.shortcutActions().completeSend(requestID: id) else {
            throw ShortcutRequestError.expired
        }
        return .result()
    }
}

enum ShortcutRequestError: LocalizedError, CustomLocalizedStringResourceConvertible {
    case expired

    var errorDescription: String? { String(localized: localizedStringResource) }

    var localizedStringResource: LocalizedStringResource {
        "This Jo request expired, finished, or was already claimed. Ask Jo again; do not reuse an earlier Request ID."
    }
}
