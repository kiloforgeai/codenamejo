import XCTest
@testable import CodenameJo

final class LocalVoiceBrainTests: XCTestCase {
    func testTheKeyAndAConnectionPickOpenAIAndOnlyTheOnDeviceModelRemainsOtherwise() {
        XCTAssertEqual(LocalVoiceBrain.engine(hasKey: true, online: true, onDeviceAvailable: false), .openAI)
        XCTAssertEqual(LocalVoiceBrain.engine(hasKey: true, online: false, onDeviceAvailable: true), .onDevice)
        XCTAssertEqual(LocalVoiceBrain.engine(hasKey: false, online: true, onDeviceAvailable: true), .onDevice)
        XCTAssertNil(LocalVoiceBrain.engine(hasKey: false, online: true, onDeviceAvailable: false))
        XCTAssertNil(LocalVoiceBrain.engine(hasKey: true, online: false, onDeviceAvailable: false))
    }

    func testTheSpokenTextIsEveryMessagesOutputTextAndNothingElse() {
        let output: [[String: Any]] = [
            ["type": "reasoning", "summary": []],
            ["type": "message", "content": [["type": "output_text", "text": "Three new."], ["type": "refusal", "refusal": "no"]]],
            ["type": "function_call", "name": "x", "arguments": "{}"],
            ["type": "message", "content": [["type": "output_text", "text": "Sarah first."]]],
        ]
        XCTAssertEqual(LocalVoiceBrain.spokenText(output), "Three new. Sarah first.")
        XCTAssertEqual(LocalVoiceBrain.spokenText([]), "")
    }

    func testTheInputCarriesTheLastExchangesOldestFirstThenTheTranscript() {
        let history = (1...10).map { LocalVoiceBrain.Exchange(user: "u\($0)", assistant: "a\($0)") }
        let items = LocalVoiceBrain.input("now", history: history)
        XCTAssertEqual(items.count, LocalVoiceBrain.remembered * 2 + 1)
        XCTAssertEqual(items.first?["content"] as? String, "u3")
        XCTAssertEqual(items[1]["role"] as? String, "assistant")
        XCTAssertEqual(items.last?["content"] as? String, "now")
        XCTAssertEqual(items.last?["role"] as? String, "user")
    }

    func testTheOfflinePromptKeepsOnlyRecentContextAndTheInstructionsEndWithTheLocalPrompt() throws {
        XCTAssertEqual(LocalVoiceBrain.offlinePrompt("hi", history: []), "hi")
        let prompt = LocalVoiceBrain.offlinePrompt("hi", history: [.init(user: "u", assistant: "a")])
        XCTAssertTrue(prompt.hasSuffix("Current user message:\nhi"))
        XCTAssertTrue(prompt.contains("User: u\nJo: a"))
        let instructions = try LocalVoiceBrain.instructions(mail: true, calendar: false, notion: false)
        XCTAssertTrue(instructions.hasSuffix(try LivePrompt.Text.bundled(LocalVoiceBrain.promptName)))
        XCTAssertTrue(instructions.contains("# You are the whole call"))
        XCTAssertFalse(instructions.contains("# You are working alone"))
    }
}
