import XCTest
@testable import CodenameJo

@MainActor
final class OnboardingDispatchRepeatTests: XCTestCase {
    func testRepeatedOnboardingDispatchGetsOneOutputAndNoLiveDispatch() {
        let client = FullDuplexVoiceClient()
        var started: [UUID] = []
        var toolUses = 0
        client.onDispatchStarted = { id, _ in started.append(id) }
        client.onToolUse = { _ in toolUses += 1 }
        defer { client.cancelDispatchesForTesting() }

        let flow = EmailOnboardingFlow(version: 2, runId: "repeat", welcome: nil)
        let args = #"{"task":"Look up tomorrow's weather in Paris","scope":"independent"}"#
        client.startOnboardingDispatchForTesting(flow: flow, callId: "first", argumentsJSON: args)
        client.startOnboardingDispatchForTesting(flow: flow, callId: "second", argumentsJSON: args)

        XCTAssertEqual(started.count, 1, "the repeat must not register a live dispatch")
        XCTAssertEqual(toolUses, 1)
        let first = client.dispatchOutputsForTesting.filter { $0.callId == "first" }
        let second = client.dispatchOutputsForTesting.filter { $0.callId == "second" }
        XCTAssertEqual(first.count, 1)
        XCTAssertTrue(first.first?.output.hasPrefix("Started.") == true)
        XCTAssertEqual(second.count, 1, "a call id gets one function output")
        XCTAssertTrue(second.first?.output.contains("already queued") == true)
        XCTAssertFalse(second.first?.output.contains("Started.") == true)
    }
}
