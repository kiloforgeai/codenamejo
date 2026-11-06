#if targetEnvironment(macCatalyst)
import SwiftUI

struct DesktopConversationView: View {
    let userWords: String
    let response: String
    let previousResponse: Bool
    let state: SessionState
    let inSession: Bool
    let stopSpeaking: () -> Void
    @State private var followsConversation = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                Label("Conversation", systemImage: "bubble.left.and.bubble.right").font(.system(size: 12, weight: .semibold))
                Spacer()
                if inSession {
                    Toggle("Follow live", isOn: $followsConversation).toggleStyle(.button).font(.caption).fixedSize()
                } else {
                    Text("Your conversation will appear here").font(.caption).foregroundStyle(.secondary)
                }
                if state == .responding {
                    Button("Stop speaking", action: stopSpeaking).font(.caption).buttonStyle(.borderless)
                }
            }.padding(.horizontal, 28).padding(.vertical, 10)
            if inSession {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            if userWords.isEmpty && response.isEmpty {
                                Text(inSession ? "Your conversation with Jo will appear here." : "Start a session to talk with Jo.")
                                    .foregroundStyle(.secondary)
                            }
                            if !userWords.isEmpty {
                                VStack(alignment: .leading, spacing: 7) {
                                    DesktopWorkspaceStyle.caption("You")
                                    Text(userWords).font(.system(size: 14)).lineSpacing(5).textSelection(.enabled)
                                }
                            }
                            if !response.isEmpty {
                                VStack(alignment: .leading, spacing: 7) {
                                    DesktopWorkspaceStyle.caption(previousResponse ? "Jo · Previous response" : "Jo")
                                    Text(response).font(.system(size: 15)).lineSpacing(4).textSelection(.enabled)
                                        .foregroundStyle(previousResponse ? .secondary : .primary)
                                }
                            }
                            if case .error(let message) = state {
                                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled)
                            }
                            Color.clear.frame(height: 1).id("conversationLatest")
                        }.padding(.horizontal, 28).padding(.bottom, 18).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onChange(of: response) { _, _ in
                        if followsConversation { proxy.scrollTo("conversationLatest", anchor: .bottom) }
                    }
                    .onChange(of: userWords) { _, _ in
                        if followsConversation { proxy.scrollTo("conversationLatest", anchor: .bottom) }
                    }
                    .onChange(of: followsConversation) { _, follow in
                        if follow { proxy.scrollTo("conversationLatest", anchor: .bottom) }
                    }
                }
            }
        }.background(DesktopWorkspaceStyle.inset.opacity(0.65)).accessibilityIdentifier("workspaceConversationPane")
    }

}
#endif
