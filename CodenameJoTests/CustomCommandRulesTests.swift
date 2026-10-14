import XCTest
@testable import CodenameJo

/// The checks a saved command passes on this phone, ported from the server's boundary tests.
final class CustomCommandRulesTests: XCTestCase {
    private let steps = [CommandAction(tool: "web_search", detail: "the company"),
                         CommandAction(tool: "summarize", detail: "two sentences")]

    private func refusal(_ keyword: String, _ actions: [CommandAction]) -> String? {
        if case .failure(let refusal) = CustomCommandRules.validateSave(keyword: keyword, actions: actions) {
            return refusal.sentence
        }
        return nil
    }

    func testAKeywordIsNormalised() throws {
        XCTAssertEqual(CustomCommandRules.normalise("  Candidate\t Screen  "), "candidate screen")
        let saved = try CustomCommandRules.validateSave(keyword: "  Candidate\t Screen  ", actions: steps).get()
        XCTAssertEqual(saved.keyword, "candidate screen")
    }

    func testRefusedKeywords() {
        XCTAssertEqual(refusal("", steps), "A command needs a keyword to answer to.")
        XCTAssertNotNil(refusal("hang up", steps))
        XCTAssertNotNil(refusal("I'm done", steps), "apostrophes are stripped before the reserved lookup")
        XCTAssertNotNil(refusal("I’m done", steps))
        XCTAssertNotNil(refusal("help", steps))
        XCTAssertTrue(refusal("one two three four five", steps)?.contains("up to 4 words") == true)
        XCTAssertNil(refusal("one two three four", steps))
    }

    func testRefusedSteps() {
        XCTAssertTrue(refusal("research", [])?.contains("has no steps") == true)
        XCTAssertTrue(refusal("research", [CommandAction(tool: "  ", detail: "x")])?.contains("has no steps") == true,
                      "a step with no tool is dropped, and nothing left is no steps")
        XCTAssertTrue(refusal("research", [CommandAction(tool: "triage_next", detail: "")])?
            .hasPrefix("A command can't walk the queue") == true)
        XCTAssertTrue(refusal("research", steps + [CommandAction(tool: "invented_tool", detail: "")])?
            .hasPrefix("A command can't do that") == true, "a disallowed step refuses the whole save")
        XCTAssertNotNil(refusal("research", [CommandAction(tool: "commands", detail: "")]))
        XCTAssertNotNil(refusal("research", [CommandAction(tool: "set_rule", detail: "")]))
    }

    func testStepsAreTrimmedAndMalformedOnesDropped() throws {
        let saved = try CustomCommandRules.validateSave(keyword: "research", actions: [
            CommandAction(tool: " web_search ", detail: "  the company "),
            CommandAction(tool: "", detail: "lost"),
        ]).get()
        XCTAssertEqual(saved.actions, [CommandAction(tool: "web_search", detail: "the company")])
    }

    func testConnectorAndCustomMCPToolsAreAllowed() {
        for tool in ["slack_send_message", "granola_get_meeting", "github_list_pull_requests", "mcp_mvp_file_issue",
                     "send_email", "gmail_search_messages", "list_calendar_events", "summarize"] {
            XCTAssertTrue(CustomCommandRules.allows(tool), tool)
        }
        for tool in ["slack_triage_next", "find_person", "dispatch", "end_session", "unknown"] {
            XCTAssertFalse(CustomCommandRules.allows(tool), tool)
        }
    }

    func testTheStepEnumIsEveryAllowedToolPlusThisSessionsCustomMCPTools() {
        let names = CustomCommandRules.allowedNames(in: ["triage_next", "mcp_x_y", "mcp_x_y"])
        XCTAssertTrue(names.contains("web_search"), "a call without web_search can still save a web step")
        XCTAssertTrue(names.contains("summarize"))
        XCTAssertFalse(names.contains("triage_next"))
        XCTAssertEqual(names.filter { $0 == "mcp_x_y" }.count, 1)
    }

    func testABackgroundRunIsAReceiptOnlyWhenEveryStepIsAWrite() {
        XCTAssertEqual(CustomCommandRules.dispatchExpects([CommandAction(tool: "archive_message", detail: ""),
                                                           CommandAction(tool: "slack_send_message", detail: "")]), .receipt)
        XCTAssertEqual(CustomCommandRules.dispatchExpects([CommandAction(tool: "archive_message", detail: ""),
                                                           CommandAction(tool: "summarize", detail: "")]), .answer)
        XCTAssertEqual(CustomCommandRules.dispatchExpects([CommandAction(tool: "mcp_x_write", detail: "")]), .answer)
        XCTAssertEqual(CustomCommandRules.dispatchExpects([]), .answer)
    }

    func testTheWorkerTaskNamesEveryStepAndTheFinalAnswer() {
        let command = CustomCommand(id: "1", keyword: "research", spoken: "Research", instruction: "Research a company",
                                    actions: steps, enabled: true, createdAt: nil)
        let task = FullDuplexVoiceClient.dispatchTask(for: command)
        XCTAssertTrue(task.contains("Run the user's saved command \"research\" exactly as stored."))
        XCTAssertTrue(task.contains("1. web_search — the company"))
        XCTAssertTrue(task.contains("2. Final answer — two sentences"))
        XCTAssertFalse(task.contains("Research a company"), "the label never reaches the worker")
    }

    func testALooseDispatchClaimsACommandOnlyByExactKeyword() {
        let make = { (keyword: String) in
            CustomCommand(id: keyword, keyword: keyword, spoken: keyword, instruction: "", actions: [],
                          enabled: true, createdAt: nil)
        }
        let commands = [make("research"), make("candidate screen")]
        XCTAssertTrue(FullDuplexVoiceClient.looksLikeSavedCommandTask("Run my saved command research"))
        XCTAssertFalse(FullDuplexVoiceClient.looksLikeSavedCommandTask("Research Acme"))
        XCTAssertEqual(FullDuplexVoiceClient.exactSavedCommandReference(
            in: "run the candidate screen command", commands: commands)?.keyword, "candidate screen")
        XCTAssertNil(FullDuplexVoiceClient.exactSavedCommandReference(in: "run the candidate command", commands: commands))
        XCTAssertNil(FullDuplexVoiceClient.exactSavedCommandReference(
            in: "run research then candidate screen command", commands: commands), "two matches is no match")
    }

    func testTheSessionGetsCommandToolsAndDispatchCommandOnlyWithCommands() throws {
        let catalog = LiveSessionSetup.Catalog.bundled
        let base = [catalog.tool("dispatch"), catalog.tool("send_email"), catalog.tool("triage_next")]
        func names(_ tools: [[String: Any]]) -> [String] { tools.compactMap { $0["name"] as? String } }

        let none = LiveSessionSetup.addingCommands(to: base, keywords: [], dispatch: true, catalog: catalog)
        XCTAssertEqual(names(none), ["dispatch", "send_email", "triage_next", "commands", "summarize"])
        let parameters = try XCTUnwrap(none[3]["parameters"] as? [String: Any])
        let actions = try XCTUnwrap((parameters["properties"] as? [String: Any])?["actions"] as? [String: Any])
        let tool = try XCTUnwrap(((actions["items"] as? [String: Any])?["properties"] as? [String: Any])?["tool"]
            as? [String: Any])
        XCTAssertEqual(tool["enum"] as? [String], CustomCommandRules.allowedNames(in: []))

        let some = LiveSessionSetup.addingCommands(to: base, keywords: ["research"], dispatch: true, catalog: catalog)
        XCTAssertEqual(names(some).last, "dispatch_command")
        XCTAssertTrue((some[0]["description"] as? String)?.hasSuffix(LiveSessionSetup.dispatchCommandNote) == true)
        let command = try XCTUnwrap(((some.last?["parameters"] as? [String: Any])?["properties"] as? [String: Any])?["command"]
            as? [String: Any])
        XCTAssertEqual(command["enum"] as? [String], ["research"])

        let off = LiveSessionSetup.addingCommands(to: base, keywords: ["research"], dispatch: false, catalog: catalog)
        XCTAssertFalse(names(off).contains("dispatch_command"))
    }

    func testThePromptCarriesTheSectionAndEveryKeyword() throws {
        var facts = LivePrompt.Facts()
        facts.commands = true
        facts.commandKeywords = ["research", "candidate screen"]
        let brain = try LivePrompt.brainInstructions(facts, timeZone: "UTC")
        XCTAssertTrue(brain.contains("# Commands"))
        XCTAssertTrue(brain.contains("# This user's commands"))
        XCTAssertTrue(brain.contains("- candidate screen"))
        XCTAssertFalse(try LivePrompt.brainInstructions(LivePrompt.Facts(), timeZone: "UTC").contains("# Commands"))
    }

    func testAMidCallEditRebuildsTheCommandToolsWithoutDuplicating() throws {
        let catalog = LiveSessionSetup.Catalog.bundled
        let base = [catalog.tool("dispatch"), catalog.tool("send_email")]
        func names(_ tools: [[String: Any]]) -> [String] { tools.compactMap { $0["name"] as? String } }
        let dialled = LiveSessionSetup.addingCommands(to: base, keywords: [], dispatch: true, catalog: catalog)
        XCTAssertFalse(names(dialled).contains("dispatch_command"))

        let saved = LiveSessionSetup.refreshingCommands(in: dialled, keywords: ["research"], catalog: catalog)
        XCTAssertEqual(names(saved), ["dispatch", "send_email", "commands", "summarize", "dispatch_command"])
        let again = LiveSessionSetup.refreshingCommands(in: saved, keywords: ["research", "standup"], catalog: catalog)
        XCTAssertEqual(names(again), names(saved))
        let note = LiveSessionSetup.dispatchCommandNote
        XCTAssertEqual((again[0]["description"] as? String)?.components(separatedBy: note).count, 2,
                       "the dispatch note is added once, not once per edit")
        let command = try XCTUnwrap(((again.last?["parameters"] as? [String: Any])?["properties"]
            as? [String: Any])?["command"] as? [String: Any])
        XCTAssertEqual(command["enum"] as? [String], ["research", "standup"])

        let emptied = LiveSessionSetup.refreshingCommands(in: again, keywords: [], catalog: catalog)
        XCTAssertFalse(names(emptied).contains("dispatch_command"))
        XCTAssertFalse((emptied[0]["description"] as? String)?.hasSuffix(note) == true)
    }
}
