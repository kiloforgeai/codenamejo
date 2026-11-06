#if targetEnvironment(macCatalyst)
import SwiftUI

struct DesktopReaderPane: View {
    @ObservedObject var viewModel: DesktopWorkspaceModel
    let retryEmailReader: () -> Void

    var body: some View {
        let presentation = viewModel.feedPresentation
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    Label(viewModel.displayedFocus == nil ? "Your work" : "In focus", systemImage: "viewfinder")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    Spacer()
                    if presentation.isTransitioning {
                        ProgressView().controlSize(.mini).accessibilityLabel("Updating the selected email")
                            .accessibilityIdentifier("feedSelectionTransition")
                    }
                    if let email = presentation.currentEmail,
                       let position = email.displayedPosition {
                        Text("\(position)\(email.displayedTotal.map { " / \($0)" } ?? "")")
                            .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
                if let focus = presentation.displayedFocus {
                    if case .email(let email) = focus, email.isBackgroundResult {
                        Label("Background result · your place in the feed is saved", systemImage: "arrow.uturn.backward")
                            .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("feedBackgroundResult")
                    }
                    focusContent(focus)
                } else if presentation.isTransitioning {
                    Text("Getting the next email ready…").foregroundStyle(.secondary)
                        .frame(minHeight: 220, alignment: .topLeading)
                } else {
                    VStack(alignment: .leading, spacing: 18) {
                        Image(systemName: viewModel.inSession ? "waveform" : "tray")
                            .font(.system(size: 30, weight: .light)).foregroundStyle(.tertiary)
                        Text(viewModel.inSession ? "Getting your work ready" : "Ready to work")
                            .font(.system(size: 28, weight: .semibold))
                        Text(viewModel.inSession
                            ? (viewModel.sessionIntent == .feed
                                ? "Jo is getting your next feed item ready. Its details will appear here."
                                : "Tell Jo what you need done. Your request and its context will appear here.")
                            : "Choose an item from your feed to read it here, or start a session and work through it with Jo.")
                            .font(.system(size: 15)).foregroundStyle(.secondary).lineSpacing(5).frame(maxWidth: 440, alignment: .leading)
                    }.padding(.vertical, 36)
                }
                Spacer(minLength: 25)
            }.padding(28).frame(maxWidth: 880, alignment: .leading).frame(maxWidth: .infinity)
        }.id(viewModel.currentFeedRowID ?? presentation.displayedSelection?.canonical)
    }

    @ViewBuilder
    private func focusContent(_ focus: FeedFocus) -> some View {
        switch focus {
        case .overview(let overview):
            VStack(alignment: .leading, spacing: 24) {
                Label("YOUR PRIORITIES", systemImage: "list.number")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Text(overview.title).font(.system(size: 26, weight: .semibold))
                ForEach(Array(overview.entries.enumerated()), id: \.offset) { index, entry in
                    HStack(alignment: .top, spacing: 18) {
                        Text(String(index + 1)).font(.system(size: 20, design: .serif))
                            .foregroundStyle(DesktopWorkspaceStyle.accent).frame(width: 24, alignment: .leading)
                        VStack(alignment: .leading, spacing: 7) {
                            Text(entry.subject).font(.system(size: 18, weight: .medium))
                            Text(entry.sender).font(.system(size: 13)).foregroundStyle(.secondary)
                            if let reason = entry.reason {
                                Text(reason).font(.system(size: 15)).foregroundStyle(.secondary).lineSpacing(4)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    if index < overview.entries.count - 1 { Divider() }
                }
                Text("Say “next” to begin with the first email.").font(.callout).foregroundStyle(.secondary)
            }.textSelection(.enabled).accessibilityIdentifier("focusedOverview")
        case .email(let email):
            DesktopEmailReaderView(email: email, state: viewModel.emailReader, retry: retryEmailReader)
        case .slack(let slack):
            VStack(alignment: .leading, spacing: 18) {
                Label(slack.workspace, systemImage: "number").font(.caption).foregroundStyle(.secondary)
                Text(slack.name).font(.system(size: 26, weight: .semibold))
                ForEach(Array(slack.messages.enumerated()), id: \.offset) { _, message in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(message.from).font(.system(size: 13, weight: .semibold))
                        Text(message.text).font(.system(size: 15)).lineSpacing(5).textSelection(.enabled)
                    }.padding(.vertical, 4)
                }
            }
        case .calendar(let calendar):
            Text("Your calendar").font(.system(size: 26, weight: .semibold))
            switch calendar {
            case .agenda(let events, let partial):
                ForEach(events, id: \.id) { event in
                    HStack(alignment: .top, spacing: 20) {
                        Group {
                            if let start = event.start, !event.allDay { Text(start, style: .time) }
                            else { Text("All day") }
                        }.font(.system(size: 12, design: .monospaced)).frame(width: 75, alignment: .leading)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(event.title).font(.system(size: 16, weight: .medium))
                            if let location = event.location, !location.isEmpty { Text(location).font(.caption).foregroundStyle(.secondary) }
                        }
                    }.padding(.vertical, 8)
                }
                if partial { Text("Some calendars could not be loaded.").font(.caption).foregroundStyle(.orange) }
            case .loading: ProgressView("Reading your calendar…")
            case .empty(let partial): Text(partial ? "No events in the calendars available. Some calendars could not be loaded." : "Your calendar is clear for the rest of today.").foregroundStyle(.secondary)
            case .unavailable: Label("Your calendar could not be loaded.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
        case .tip(let tip):
            Text("A note from Jo").font(.system(size: 26, weight: .semibold))
            Text(tip.copy).font(.title3).lineSpacing(6)
        case .about(let facts):
            Text("Getting to know your work").font(.system(size: 26, weight: .semibold))
            ForEach(facts, id: \.self) { Text($0).font(.body) }
        case .emailStatus(let status):
            Text(status == .unavailable ? "Email needs attention." : "Through this part of your inbox.")
                .font(.system(size: 26, weight: .semibold))
            Text(status == .unavailable ? "Jo could not load the mail for this part of the feed." : "Keep talking. Jo will guide you to what’s next.").foregroundStyle(.secondary)
        case .slackStatus(let status):
            Text(status == .stopped ? "Slack is paused." : "Through your Slack conversations.")
                .font(.system(size: 26, weight: .semibold))
        case .complete:
            Label("You’re caught up", systemImage: "checkmark.circle.fill")
                .font(.system(size: 28, weight: .semibold)).foregroundStyle(DesktopWorkspaceStyle.accent)
            Text("This pass through your feed is finished. Jo is here for whatever you want to tackle next.")
                .foregroundStyle(.secondary).lineSpacing(6)
        }
    }

}
#endif
