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
            Text(email.subject.isEmpty ? "No subject" : email.subject)
                .font(.system(size: 26, weight: .semibold)).textSelection(.enabled)
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
                    Text(email.sender).font(.headline).textSelection(.enabled)
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
                    Text(message.from).font(.system(size: 14, weight: .semibold)).textSelection(.enabled)
                    Spacer()
                    if inThread, selected { Text("IN FOCUS").font(.caption2.weight(.semibold)).foregroundStyle(.tint) }
                }
                if !message.to.isEmpty { Text("To: \(message.to)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                if !message.cc.isEmpty { Text("Cc: \(message.cc)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                if !message.date.isEmpty { Text(message.date).font(.caption).foregroundStyle(.secondary) }
                if inThread, message.subject != email.subject { Text(message.subject).font(.headline).textSelection(.enabled) }
            }
            Divider()
            if let reason = message.error { failure(reason) }
            else {
                Text(message.text).font(.system(size: 16)).lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
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

    private func failure(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Couldn’t load the complete email", systemImage: "exclamationmark.triangle").font(.headline)
            Text(reason).foregroundStyle(.secondary)
            Button("Retry", action: retry).buttonStyle(.bordered).accessibilityIdentifier("retryEmailReader")
        }.accessibilityIdentifier("emailReaderFailure")
    }
}
#endif
