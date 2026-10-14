import XCTest
@testable import CodenameJo

final class LivePromptTests: XCTestCase {
    func testBundledPromptBuildsBothConfigsFromFacts() throws {
        var facts = LivePrompt.Facts()
        facts.skills = ["email"]
        facts.localTriage = true
        facts.triageScope = "unread"
        let tools: [Any] = [["type": "function", "name": "send_text"]]
        let configs = try LivePrompt.configs(facts: facts, tools: tools, fastActions: true, timeZone: "UTC")

        let brain = try XCTUnwrap(configs.brain["instructions"] as? String)
        XCTAssertTrue(brain.hasPrefix("# Role"))
        XCTAssertTrue(brain.contains("# The email queue, one correction"))
        XCTAssertTrue(brain.contains("your unread mail"))
        XCTAssertFalse(brain.contains("{PILE}"))
        XCTAssertFalse(brain.contains("<!-- guardrail -->"))
        XCTAssertTrue(brain.contains("You are the task backend for Jo's voice conversation."))
        XCTAssertEqual(configs.brain["model"] as? String, LivePrompt.brainModel)
        XCTAssertEqual(configs.brain["service_tier"] as? String, "priority")

        let speaker = try XCTUnwrap(configs.session["instructions"] as? String)
        XCTAssertTrue(speaker.contains("send SMS/iMessage texts"))
        XCTAssertTrue(speaker.contains("The application may execute an exact completed"))
        XCTAssertEqual(configs.session["delegation"] as? [String: String], ["type": "client"])
    }
}
