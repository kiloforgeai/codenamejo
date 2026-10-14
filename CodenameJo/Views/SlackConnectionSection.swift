import SwiftUI

extension ProfileConnectionsView {
    /// Slack: one row per workspace in this profile. A workspace's refresh token dies after 30
    /// days unused, so a row can be connected and broken at once, like Notion's.
    @ViewBuilder
    var slackSection: some View {
        if viewModel.slackAvailable {
            Section {
                ForEach(viewModel.slackAccounts, id: \.self) { workspace in
                    let broken = viewModel.slackNeedsReauth.contains(workspace)
                    connectorAccountRow(
                        icon: "bubble.left.and.bubble.right.fill",
                        service: "Slack",
                        title: workspace,
                        subtitle: broken ? "Needs reconnecting" : nil,
                        needsAttention: broken,
                        identifier: "slackAccountRow_\(workspace)",
                        menu: {
                            Button(broken ? "Reconnect" : "Replace connection") {
                                interactor.connectSlack(viewModel: viewModel)
                            }
                            .accessibilityIdentifier("reconnectSlack_\(workspace)")

                            Button("Remove", role: .destructive) {
                                interactor.removeSlack(workspace, viewModel: viewModel)
                            }
                        }
                    )
                }

                connectorConnectButton(
                    title: viewModel.slackAccounts.isEmpty ? "Connect Slack" : "Add another workspace",
                    connector: "slack",
                    identifier: "connectSlackButton",
                    action: { interactor.connectSlack(viewModel: viewModel) }
                )

                connectorDetailRow(
                    name: "Slack",
                    icon: "number",
                    service: "Slack",
                    capabilities: .slack,
                    summary: ConnectorCopy.slack,
                    identifier: "slackDetailRow"
                )
            } header: {
                connectorHeader("Slack", icon: "bubble.left.and.bubble.right.fill", service: "Slack")
            } footer: {
                connectorFooter(connector: "slack")
            }
        }
    }
}

extension ConnectorCopy {
    static let slack =
        "Catches you up and replies, reading only what you can already see. Posting goes "
            + "as soon as you ask, without a confirmation."
}

extension Array where Element == ConnectorCapability {
    /// Capabilities rather than scopes: four history scopes back one "catch up".
    static let slack: [ConnectorCapability] = [
        ConnectorCapability(
            scope: "slack.catchup",
            label: "Catch up",
            icon: "bubble.left.and.bubble.right",
            detail: "Walk through what you missed one conversation at a time, deciding what to "
                + "do about each. Replying or reacting marks that conversation read. "
                + "Slack doesn't always say where you've read up to in DMs."
        ),
        ConnectorCapability(
            scope: "slack.search",
            label: "Search",
            icon: "magnifyingglass",
            detail: "Find messages across the workspace by who sent them or what they said."
        ),
        ConnectorCapability(
            scope: "slack.post",
            label: "Reply",
            icon: "arrowshape.turn.up.left",
            detail: "Post a message to a channel or DM, now or at a time you name. It goes as soon "
                + "as you ask — you aren't asked to confirm, and everyone in the channel sees it."
        ),
        ConnectorCapability(
            scope: "slack.react",
            label: "React",
            icon: "face.smiling",
            detail: "Add an emoji reaction to a message. It goes as soon as you ask, under "
                + "your own name, and you can take it off again."
        ),
        ConnectorCapability(
            scope: "slack.markread",
            label: "Mark read",
            icon: "envelope.open",
            detail: "Mark a conversation read, or put it back to unread, as you ask. It "
                + "changes your own unread badges and nobody else's."
        ),
        ConnectorCapability(
            scope: "slack.asyou",
            label: "Only what you see",
            icon: "person.crop.circle",
            detail: "It reads as you, from this phone, so it reaches exactly the channels and DMs "
                + "you already have access to. The token stays on this phone."
        ),
        ConnectorCapability(
            scope: "slack.session",
            label: "Reconnect after a month away",
            icon: "arrow.clockwise",
            detail: "Slack ends this connection if it goes unused for 30 days. Using it keeps it "
                + "alive; if it lapses, this row will say so."
        ),
    ]
}
