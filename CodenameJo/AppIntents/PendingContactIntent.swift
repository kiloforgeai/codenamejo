import AppIntents
import FactoryKit
import Foundation

/// Resolves the requested contact for the matching Shortcuts request.
@available(iOS 27, *)
struct PendingContactIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Jo Contact"
    static var description = IntentDescription(
        "Returns the contact Codename Jo is asking about, ready for Find Message's Sender or Send Message's Recipients.",
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
    func perform() async throws -> some ReturnsValue<IntentPerson> {
        let runner = Container.shared.shortcutActions()
        guard let id = UUID(uuidString: requestID), runner.matches(id) else {
            throw ShortcutRequestError.expired
        }
        let about = runner.pendingSearchName ?? runner.pendingRecipient ?? ""
        do {
            guard let person = try await Container.shared.phoneContacts().person(for: about) else {
                throw PendingContactError.noContact(about)
            }
            guard runner.matches(id) else { throw ShortcutRequestError.expired }
            runner.bindReadContact(person, requestID: id)
            return .result(value: person)
        } catch {
            runner.fail(error.localizedDescription, requestID: id)
            throw error
        }
    }
}

enum PendingContactError: LocalizedError, CustomLocalizedStringResourceConvertible {
    case noContact(String)

    var errorDescription: String? { String(localized: localizedStringResource) }

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noContact(let name):
            name.isEmpty
                ? "Codename Jo has no contact request waiting."
                : "No contact named \(name) on this phone."
        }
    }
}
