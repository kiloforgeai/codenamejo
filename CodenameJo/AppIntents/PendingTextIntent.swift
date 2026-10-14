import AppIntents
import FactoryKit
import Foundation

/// The text Jo has queued for the user's own shortcut to send.
struct PendingText: TransientAppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Pending Text")

    @Property(title: "Recipient") var recipient: String
    @Property(title: "Body") var body: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(recipient)", subtitle: "\(body)")
    }

    init() {}

    init(recipient: String, body: String) {
        self.init()
        self.recipient = recipient
        self.body = body
    }
}

/// Hands the exact queued recipient and body to Send Message.
@available(iOS 27, *)
struct PendingTextIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Pending Text"
    static var description = IntentDescription(
        "Returns the recipient and message Codename Jo is waiting to send. Use the original Request ID. Follow it with Send Message using its Recipient and Body, then Complete Jo Send.",
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
    func perform() async throws -> some ReturnsValue<PendingText> {
        let runner = Container.shared.shortcutActions()
        guard let id = UUID(uuidString: requestID), runner.matches(id) else {
            throw ShortcutRequestError.expired
        }
        guard let proposed = runner.pendingText(requestID: id) else {
            throw PendingTextError.nothingWaiting
        }
        // Jo confirms on the call; no Shortcuts prompt, so sending stays hands-free.
        RealtimeLog.log("shortcuts: Get Pending Text handing over a \(proposed.body.count)-char text")
        guard let text = runner.consumePending(requestID: id) else {
            throw ShortcutRequestError.expired
        }
        return .result(value: text)
    }
}

enum PendingTextError: Error, CustomLocalizedStringResourceConvertible {
    case nothingWaiting

    var localizedStringResource: LocalizedStringResource {
        "Codename Jo has no text waiting to be sent."
    }
}
