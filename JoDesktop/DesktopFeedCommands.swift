#if targetEnvironment(macCatalyst)
import SwiftUI
import UIKit
import WebKit

struct DesktopFeedCommandContext {
    let disabledReason: String?
    let action: (LiveFastAction) -> Void
    let focusFeed: () -> Void
    let refresh: () -> Void
    let showCommands: () -> Void
    let showReference: () -> Void
}

private struct DesktopFeedCommandKey: FocusedValueKey { typealias Value = DesktopFeedCommandContext }
extension FocusedValues {
    var desktopFeedCommands: DesktopFeedCommandContext? {
        get { self[DesktopFeedCommandKey.self] }
        set { self[DesktopFeedCommandKey.self] = newValue }
    }
}

struct DesktopFeedCommands: Commands {
    @FocusedValue(\.desktopFeedCommands) private var feed

    var body: some Commands {
        CommandMenu("Feed") {
            Button("Focus work feed") { feed?.focusFeed() }
                .keyboardShortcut(.escape, modifiers: [])
                .buttonRepeatBehavior(.disabled).disabled(feed == nil)
            Divider()
            Button("Archive") { feed?.action(.archive) }
                .keyboardShortcut("a", modifiers: [.control, .command])
                .buttonRepeatBehavior(.disabled)
                .disabled(feed == nil || feed?.disabledReason != nil)
                .help(feed?.disabledReason ?? "Archive the selected email")
            Button("Next — leave unread") { feed?.action(.next) }
                .keyboardShortcut(.rightArrow, modifiers: [.control, .command])
                .buttonRepeatBehavior(.disabled)
                .disabled(feed == nil || feed?.disabledReason != nil)
                .help(feed?.disabledReason ?? "Move on without changing the email")
            Divider()
            Button("Actions and commands…") { feed?.showCommands() }
                .keyboardShortcut("k", modifiers: [.control, .command])
                .buttonRepeatBehavior(.disabled).disabled(feed == nil)
            Button("Refresh feed") { feed?.refresh() }
                .keyboardShortcut("r", modifiers: [.control, .command])
                .buttonRepeatBehavior(.disabled).disabled(feed == nil)
            Divider()
            Button("Keyboard shortcuts…") { feed?.showReference() }.disabled(feed == nil)
        }
    }
}

@MainActor
enum DesktopKeyboardFocus {
    static func allowsFeedAction(in window: UIWindow?) -> Bool {
        guard let window, window.isKeyWindow, !window.isHidden,
              window.windowScene?.activationState == .foregroundActive,
              UIApplication.shared.applicationState == .active else { return false }
        return !blocksFeedAction(firstResponder(in: window))
    }

    static func blocksFeedAction(_ responder: UIView?) -> Bool {
        guard let responder else { return false }
        if let field = responder as? UITextView { return field.isEditable }
        if responder is UITextInput || responder is UIKeyInput { return true }
        var view: UIView? = responder
        while let current = view {
            if current is WKWebView { return true }
            view = current.superview
        }
        return false
    }

    static func firstResponder(in view: UIView) -> UIView? {
        if view.isFirstResponder { return view }
        for child in view.subviews {
            if let responder = firstResponder(in: child) { return responder }
        }
        return nil
    }
}

@MainActor
class DesktopKeyboardWindow: ObservableObject { weak var value: UIWindow? }

struct DesktopKeyboardWindowProbe: UIViewRepresentable {
    let found: (UIWindow?) -> Void
    func makeUIView(context: Context) -> Probe { Probe() }
    func updateUIView(_ view: Probe, context: Context) {
        view.found = found
        DispatchQueue.main.async { [weak view] in view?.found?(view?.window) }
    }
    class Probe: UIView {
        var found: ((UIWindow?) -> Void)?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            DispatchQueue.main.async { [weak self] in self?.found?(self?.window) }
        }
    }
}
#endif
