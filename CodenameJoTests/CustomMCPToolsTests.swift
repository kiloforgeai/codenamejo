import FactoryKit
import XCTest
@testable import CodenameJo

final class CustomMCPToolsTests: XCTestCase {
    private func server(_ id: String = "11111111-2222-3333-4444-555555555555", name: String = "MVP",
                        tools: [CustomMCPServer.Tool] = []) -> CustomMCPServer {
        CustomMCPServer(id: id, name: name, endpoint: URL(string: "https://mcp.example.test/mcp")!,
                        auth: .bearer, profileId: "p1", ownerId: "u1", tools: tools, addedAt: Date())
    }

    private func tool(_ name: String, description: String = "Does the thing",
                      schema: String = #"{"type":"object","properties":{"title":{"type":"string"}},"required":["title"]}"#)
        -> CustomMCPServer.Tool {
        CustomMCPServer.Tool(name: name, description: description, inputSchemaJSON: schema)
    }

    private func grant(needsReauth: Bool = false) -> RemoteMCPGrant {
        var grant = CustomMCPConnector.staticGrant(token: "tok", server: server())
        grant.needsReauth = needsReauth
        return grant
    }

    // MARK: - Names

    func testFunctionNamesCarryThePrefixTheServerAndASanitisedToolName() {
        let mvp = server(name: "MVP Agent Tools!")
        XCTAssertEqual(CustomMCPTools.functionName(server: mvp, tool: "file_issue"), "mcp_mvpagenttool_file_issue")
        XCTAssertEqual(CustomMCPTools.functionName(server: mvp, tool: "get.pr/details"), "mcp_mvpagenttool_get_pr_details")
        XCTAssertTrue(CustomMCPTools.isCustomTool("mcp_mvp_file_issue"))
        XCTAssertFalse(CustomMCPTools.isCustomTool("github_merge_pull_request"))
    }

    func testAServerNamedInSymbolsFallsBackToItsIdAndLongNamesAreCut() {
        let symbols = server("abcdef12-0000", name: "日本語 🚀")
        XCTAssertEqual(CustomMCPTools.slug(symbols), "abcdef")
        let long = CustomMCPTools.functionName(server: server(), tool: String(repeating: "x", count: 100))
        XCTAssertEqual(long.count, CustomMCPTools.maxFunctionName)
        XCTAssertTrue(long.hasPrefix("mcp_mvp_"))
    }

    func testBareNameAndHumanizedReadAsTheToolAlone() {
        XCTAssertEqual(CustomMCPTools.bareName("mcp_mvp_file_issue"), "file_issue")
        XCTAssertEqual(CustomMCPTools.bareName("mcp_mvp_"), "mvp_")
        XCTAssertEqual(CustomMCPTools.bareName("not_ours"), "not_ours")
        XCTAssertEqual(CustomMCPTools.humanized("file_issue"), "File issue")
        XCTAssertEqual(CustomMCPTools.humanized("get-pr-details"), "Get pr details")
        XCTAssertEqual(ToolNarration.canonical("mcp_mvp_file_issue"), "file_issue")
        XCTAssertEqual(ToolNarration.progressLabel(for: "mcp_mvp_file_issue"), "file issue")
        XCTAssertEqual(ToolNarration.sourceIcon(for: "mcp_mvp_file_issue"), "puzzlepiece.extension.fill")
    }

    // MARK: - Definitions

    func testADefinitionPassesTheServersSchemaThroughUnderTheServersName() throws {
        let definition = CustomMCPTools.definition(server: server(), tool: tool("file_issue", description: "  File a GitHub issue.  "))
        XCTAssertEqual(definition["type"] as? String, "function")
        XCTAssertEqual(definition["name"] as? String, "mcp_mvp_file_issue")
        XCTAssertEqual(definition["description"] as? String, "[MVP] File a GitHub issue.")
        XCTAssertEqual(definition["strict"] as? Bool, false)
        let parameters = try XCTUnwrap(definition["parameters"] as? [String: Any])
        XCTAssertEqual(parameters["type"] as? String, "object")
        XCTAssertEqual(parameters["required"] as? [String], ["title"])
        XCTAssertNotNil((parameters["properties"] as? [String: Any])?["title"])
    }

    func testAToolWithNoSchemaOrDescriptionStillDeclaresAnObject() throws {
        let definition = CustomMCPTools.definition(server: server(), tool: tool("ping", description: "", schema: "{\"$schema\":\"x\"}"))
        XCTAssertEqual(definition["description"] as? String, "[MVP] A tool from MVP.")
        let parameters = try XCTUnwrap(definition["parameters"] as? [String: Any])
        XCTAssertEqual(parameters["type"] as? String, "object")
        XCTAssertNil(parameters["$schema"])
        XCTAssertEqual((parameters["properties"] as? [String: Any])?.count, 0)
    }

    func testDefinitionsSkipUnusableServersAndDuplicateNames() {
        let a = server("a", name: "MVP", tools: [tool("file_issue"), tool("file_issue")])
        let b = server("b", name: "Other", tools: [tool("ping")])
        let names = CustomMCPTools.definitions(servers: [a, b], usable: { $0.id == "a" })
            .compactMap { $0["name"] as? String }
        XCTAssertEqual(names, ["mcp_mvp_file_issue"])
    }

    // MARK: - Run

    func testRunRelaysToTheServerUnderTheVendorsToolName() async throws {
        let mvp = server(tools: [tool("file_issue")])
        var calls: [(String, String, [String: Any])] = []
        let result = await CustomMCPTools.run(
            name: "mcp_mvp_file_issue", argumentsJSON: #"{"title":"Crash on launch"}"#,
            servers: [mvp], grant: { _ in self.grant() },
            call: { server, grant, tool, arguments in
                calls.append((server.id, tool, arguments))
                XCTAssertEqual(grant.accessToken, "tok")
                return RemoteMCPToolResult(text: "Filed #12", isError: false)
            })
        XCTAssertEqual(result.text, "Filed #12")
        XCTAssertEqual(result.ok, true)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].0, mvp.id)
        XCTAssertEqual(calls[0].1, "file_issue")
        XCTAssertEqual(calls[0].2["title"] as? String, "Crash on launch")
    }

    func testRunRefusesAnUnknownNameAndARefusedCredentialWithoutCalling() async {
        let mvp = server(tools: [tool("file_issue")])
        let unknown = await CustomMCPTools.run(name: "mcp_mvp_delete_everything", argumentsJSON: "{}", servers: [mvp],
                                               grant: { _ in self.grant() }, call: { _, _, _, _ in XCTFail("called"); return .init(text: "", isError: false) })
        XCTAssertEqual(unknown.ok, false)
        XCTAssertTrue(unknown.text.contains("no tool called"))

        let refused = await CustomMCPTools.run(name: "mcp_mvp_file_issue", argumentsJSON: "{}", servers: [mvp],
                                               grant: { _ in self.grant(needsReauth: true) }, call: { _, _, _, _ in XCTFail("called"); return .init(text: "", isError: false) })
        XCTAssertEqual(refused.ok, false)
        XCTAssertTrue(refused.text.contains("MVP needs reconnecting"))
    }

    func testServerErrorsReachTheModelAsTheServersOwnWordsAndTransportFailuresAsOurs() async {
        let mvp = server(tools: [tool("file_issue")])
        let vendor = await CustomMCPTools.run(name: "mcp_mvp_file_issue", argumentsJSON: "{}", servers: [mvp],
                                              grant: { _ in self.grant() }, call: { _, _, _, _ in .init(text: "title is required", isError: true) })
        XCTAssertEqual(vendor.text, "title is required")
        XCTAssertEqual(vendor.ok, false)

        let unauthorized = await CustomMCPTools.run(name: "mcp_mvp_file_issue", argumentsJSON: "{}", servers: [mvp],
                                                    grant: { _ in self.grant() }, call: { _, _, _, _ in throw RemoteMCPError.unauthorized(status: 401) })
        XCTAssertTrue(unauthorized.text.contains("MVP rejected the connection"))
        let down = await CustomMCPTools.run(name: "mcp_mvp_file_issue", argumentsJSON: "{}", servers: [mvp],
                                            grant: { _ in self.grant() }, call: { _, _, _, _ in throw RemoteMCPError.http(status: 503, body: "") })
        XCTAssertTrue(down.text.contains("MVP is having trouble"))
        let empty = await CustomMCPTools.run(name: "mcp_mvp_file_issue", argumentsJSON: "{}", servers: [mvp],
                                             grant: { _ in self.grant() }, call: { _, _, _, _ in .init(text: "", isError: false) })
        XCTAssertEqual(empty.text, "MVP returned nothing for that.")
    }

    func testAnOversizedResultIsCutWithANote() {
        let clipped = CustomMCPTools.clipped(String(repeating: "a", count: CustomMCPTools.resultLimit + 10), server: "MVP")
        XCTAssertTrue(clipped.hasSuffix("Ask for something narrower.]"))
        XCTAssertLessThan(clipped.count, CustomMCPTools.resultLimit + 120)
        XCTAssertEqual(CustomMCPTools.clipped("short", server: "MVP"), "short")
    }

    // MARK: - Session

    func testTheSessionDeclaresTheToolsAndNamesTheServers() throws {
        let catalog = LiveSessionSetup.Catalog.bundled
        var state = LiveSessionSetup.State(inboxes: ["a@x.test"])
        let off = LiveSessionSetup.resolve(.init(), state, catalog: catalog)
        XCTAssertFalse(off.tools.contains { CustomMCPTools.isCustomTool($0["name"] as? String ?? "") })
        XCTAssertNil(off.prompt["customMCP"])

        let mvp = server(tools: [tool("file_issue")])
        state.customMCPTools = CustomMCPTools.definitions(servers: [mvp], usable: { _ in true })
        state.customMCPServers = ["MVP"]
        state.customMCPNeedsReauth = ["Old"]
        let on = LiveSessionSetup.resolve(.init(), state, catalog: catalog)
        XCTAssertEqual(on.tools.compactMap { $0["name"] as? String }.last, "mcp_mvp_file_issue")
        XCTAssertEqual(on.prompt["customMCP"] as? [String], ["MVP"])
        XCTAssertEqual(on.prompt["customMCPNeedsReauth"] as? [String], ["Old"])
        XCTAssertTrue(LiveFastAction.allowsFollowup(name: "mcp_mvp_file_issue", arguments: "{}", step: nil))
    }

    func testThePromptNamesTheServersAndTheOnesToReconnect() throws {
        let facts = LivePrompt.Facts(["skills": ["email"], "customMCP": ["MVP", "Lab"], "customMCPNeedsReauth": ["Old"]])
        let brain = try LivePrompt.brainInstructions(facts, timeZone: "UTC")
        XCTAssertTrue(brain.contains("tool servers to this app: MVP, Lab."))
        XCTAssertTrue(brain.contains("their Old server refused the stored credential"))
        let healthy = try LivePrompt.brainInstructions(LivePrompt.Facts(["skills": ["email"]]), timeZone: "UTC")
        XCTAssertFalse(healthy.contains("tool servers"))
    }
}
