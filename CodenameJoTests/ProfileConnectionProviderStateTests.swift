import XCTest
@testable import CodenameJo

@MainActor
final class ProfileConnectionProviderStateTests: XCTestCase {
    func testProviderSummariesCoverEmptySingleMultipleAndAttentionStates() {
        let viewModel = ProfileViewModel()
        viewModel.gmailAvailable = true

        XCTAssertEqual(ProfileConnectionProvider.google.state(in: viewModel).summary, "Not connected")

        viewModel.gmailAccounts = ["one@example.com"]
        XCTAssertEqual(ProfileConnectionProvider.google.state(in: viewModel).summary, "1 account connected")

        viewModel.gmailAccounts.append("two@example.com")
        XCTAssertEqual(ProfileConnectionProvider.google.state(in: viewModel).summary, "2 accounts connected")

        viewModel.gmailNeedsReauth = ["one@example.com"]
        let warning = ProfileConnectionProvider.google.state(in: viewModel)
        XCTAssertTrue(warning.needsAttention)
        XCTAssertEqual(warning.summary, "Needs reconnecting")
    }

    func testNotionFollowsTheBrokerAndWarnsOnARejectedCredential() {
        let viewModel = ProfileViewModel()
        XCTAssertFalse(ProfileConnectionProvider.notion.state(in: viewModel).available,
                       "an absent field decodes as false, which hides the section")

        viewModel.notionMcpAvailable = true
        XCTAssertTrue(ProfileConnectionProvider.notion.state(in: viewModel).available)
        XCTAssertEqual(ProfileConnectionProvider.notion.state(in: viewModel).summary, "Not connected")

        viewModel.notionMcpAccounts = ["Notion"]
        XCTAssertEqual(ProfileConnectionProvider.notion.state(in: viewModel).accountCount, 1)
        XCTAssertFalse(ProfileConnectionProvider.notion.state(in: viewModel).needsAttention)

        viewModel.notionMcpNeedsReauth = ["Notion"]
        let warning = ProfileConnectionProvider.notion.state(in: viewModel)
        XCTAssertTrue(warning.needsAttention)
        XCTAssertEqual(warning.summary, "Needs reconnecting")
    }

    func testCustomServersCountAsServersAndWarnWhenOneIsRefused() {
        let viewModel = ProfileViewModel()
        XCTAssertFalse(ProfileConnectionProvider.custom.state(in: viewModel).available)

        viewModel.customMCPAvailable = true
        XCTAssertEqual(ProfileConnectionProvider.custom.state(in: viewModel).summary, "Not connected")

        let server = CustomMCPServer(id: "s1", name: "MVP", endpoint: URL(string: "https://mcp.example.test/mcp")!,
                                     auth: .bearer, profileId: "p1", ownerId: "u1", addedAt: Date())
        viewModel.customMCPServers = [CustomMCPServerStatus(server, needsReauth: false)]
        XCTAssertEqual(ProfileConnectionProvider.custom.state(in: viewModel).summary, "1 server connected")

        viewModel.customMCPServers.append(CustomMCPServerStatus(server, needsReauth: true))
        let warning = ProfileConnectionProvider.custom.state(in: viewModel)
        XCTAssertEqual(warning.accountCount, 2)
        XCTAssertTrue(warning.needsAttention)
        XCTAssertEqual(warning.summary, "Needs reconnecting")
    }

    func testEveryProviderReadsItsOwnAccountAndWarningState() {
        let viewModel = ProfileViewModel()
        viewModel.gmailAvailable = true
        viewModel.gmailAccounts = ["mail@example.com"]
        viewModel.gmailNeedsReauth = ["mail@example.com"]

        XCTAssertEqual(ProfileConnectionProvider.google.state(in: viewModel).accountCount, 1)
        XCTAssertTrue(ProfileConnectionProvider.google.state(in: viewModel).needsAttention)
        XCTAssertEqual(ProfileConnectionProvider.google.state(in: viewModel).summary, "Needs reconnecting")
        XCTAssertFalse(ProfileConnectionProvider.notion.state(in: viewModel).available)
    }
}
