#if targetEnvironment(macCatalyst)
import SwiftUI

struct DesktopEmailReaderView: View {
    let email: FeedFocus.Email
    let state: DesktopEmailReader.State
    let retry: () -> Void
    @State private var showsThread = false

    private var matchesSelection: Bool {
        state.request?.selection == MailSelection(account: email.account, messageID: email.messageId ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Label(email.account, systemImage: "envelope")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                if let url = EmailPreview.gmailURL(account: email.account, messageID: email.messageId) {
                    Link(destination: url) { Label("Open in Gmail", systemImage: "arrow.up.right") }
                        .font(.callout).accessibilityIdentifier("openFocusedEmail")
                }
            }
            selectable(email.subject.isEmpty ? "No subject" : email.subject, field: "subject", size: 26, weight: .semibold)
            if email.messageId == nil {
                Text("This feed item has no email identifier, so its contents cannot be loaded.").foregroundStyle(.secondary)
            } else if matchesSelection {
                switch state {
                case .ready(_, let content):
                    if content.messages.count > 1 {
                        Picker("Email or complete thread", selection: $showsThread) {
                            Text("Email").tag(false)
                            Text("Thread (\(content.messages.count))").tag(true)
                        }.pickerStyle(.segmented).frame(maxWidth: 260)
                            .accessibilityIdentifier("emailReaderMode")
                    }
                    let messages = showsThread ? content.messages : content.messages.filter { $0.id == content.selectedID }
                    LazyVStack(alignment: .leading, spacing: 32) {
                        ForEach(messages) { message in
                            messageContent(message, selected: message.id == content.selectedID, inThread: showsThread)
                            if message.id != messages.last?.id { Divider() }
                        }
                    }
                case .failed(_, let reason):
                    failure(reason)
                case .headersOnly:
                    selectable(email.sender, field: "sender", size: 14, weight: .semibold)
                    Text("This profile is set to headers only. Change the mail preference in Settings to display message bodies.")
                        .foregroundStyle(.secondary).accessibilityIdentifier("emailReaderHeadersOnly")
                case .loading, .idle:
                    ProgressView("Loading the complete email…").accessibilityIdentifier("emailReaderLoading")
                }
            } else {
                ProgressView("Loading the complete email…").accessibilityIdentifier("emailReaderLoading")
            }
        }
        .onChange(of: email.messageId) { _, _ in showsThread = false }
        .onChange(of: email.account) { _, _ in showsThread = false }
        .accessibilityIdentifier("focusedEmail")
    }

    private func messageContent(_ message: DesktopEmailReader.Message, selected: Bool, inThread: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    selectable(message.from, field: "from_\(message.id)", size: 14, weight: .semibold)
                    Spacer()
                    if inThread, selected { Text("IN FOCUS").font(.caption2.weight(.semibold)).foregroundStyle(.tint) }
                }
                if !message.to.isEmpty { selectable("To: \(message.to)", field: "to_\(message.id)", size: 12, secondary: true) }
                if !message.cc.isEmpty { selectable("Cc: \(message.cc)", field: "cc_\(message.id)", size: 12, secondary: true) }
                if !message.date.isEmpty { Text(message.date).font(.caption).foregroundStyle(.secondary) }
                if inThread, message.subject != email.subject { selectable(message.subject, field: "subject_\(message.id)", size: 14, weight: .semibold) }
            }
            Divider()
            if let reason = message.error { failure(reason) }
            else {
                DesktopSelectableText(text: message.body, identity: "\(email.account):body:\(message.id)")
                    .accessibilityIdentifier("fullEmailBody_\(message.id)")
            }
            if !message.attachments.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Attachments").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(Array(message.attachments.enumerated()), id: \.offset) { _, name in
                        Label(name, systemImage: "paperclip").font(.callout).textSelection(.enabled)
                    }
                    Text("Open in Gmail to view attachments.").font(.caption).foregroundStyle(.secondary)
                }.padding(.top, 6)
            }
        }.accessibilityIdentifier("readerMessage_\(message.id)")
    }

    private func selectable(_ text: String, field: String, size: CGFloat, weight: UIFont.Weight = .regular,
                            secondary: Bool = false) -> some View {
        DesktopSelectableText(text: AttributedString(text), identity: "\(email.account):\(email.messageId ?? "none"):\(field)",
                              size: size, weight: weight, secondary: secondary, lineSpacing: 0)
    }

    private func failure(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Couldn’t load the complete email", systemImage: "exclamationmark.triangle").font(.headline)
            Text(reason).foregroundStyle(.secondary)
            Button("Retry", action: retry).buttonStyle(.bordered).accessibilityIdentifier("retryEmailReader")
        }.accessibilityIdentifier("emailReaderFailure")
    }
}
#endif
