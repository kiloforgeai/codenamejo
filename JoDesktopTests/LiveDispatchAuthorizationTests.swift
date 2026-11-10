import XCTest
@testable import CodenameJo

@MainActor
final class LiveDispatchAuthorizationTests: XCTestCase {
    @MainActor private final class Harness {
        var sent: [[String: Any]] = []
        var grants: [String?] = []
        var finished = false
        var scope: String? = "profile-a"
        lazy var adapter: LiveSessionAdapter = LiveSessionAdapter(wire: { [weak self] in self?.sent.append($0) }, emit: { [weak self] signal in
            guard let self else { return }
            if case .liveInputFinished = signal { finished = true }
            if case .liveFunction(let call) = signal { grants.append(adapter.dispatchRequest(for: call.id)) }
        })
        func receive(_ event: [String: Any]) throws {
            adapter.receive(try JSONSerialization.data(withJSONObject: event))
        }
        func input(_ text: String, time: Double = 100) throws {
            finished = false
            try receive(["type": "session.input_transcript.delta", "delta": text, "start_ms": time, "end_ms": time + 100])
        }
        func settled() async throws {
            for _ in 0..<400 where !finished { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertTrue(finished)
        }
        func start(_ text: String, desktop: Bool = false) async throws {
            adapter.silentInputRecoveryDelay = 60
            adapter.clientBrainState = { [weak self] in ("{}", self?.scope) }
            try receive(["type": "session.started"])
            if desktop { adapter.beginDesktopInteraction(origin: "archive", revision: 1) }
            try input(text)
            try await settled()
            try receive(["type": "session.delegation.created", "offset_ms": 200,
                "delegation": ["id": "d1", "response_id": "r1"]])
            try receive(["type": "response.event", "event": ["type": "response.created", "response": ["id": "r1"]]])
        }
        func call(_ name: String = "dispatch", id: String = "call-1") throws {
            try receive(["type": "response.event", "event": ["type": "response.output_item.done", "response_id": "r1",
                "item": ["type": "function_call", "call_id": id, "name": name, "arguments": "{}"]]])
        }
        func result() {
            adapter.outbound(["type": "conversation.item.create", "item": ["type": "function_call_output",
                "call_id": "call-1", "output": "Started. Request accepted."]])
        }
    }

    func testAuthorizationExistsInsideRealToolCallbackAndExpiresWithResult() async throws {
        for (name, request) in [("dispatch", "Search Example Workspace for Project notes. Only find it; do not change anything."),
                                ("dispatch", "Research the project in the background"),
                                ("dispatch_command", "Run my follow-up command")] {
            let h = Harness(); defer { h.adapter.close() }
            try await h.start(request, desktop: true)
            try h.call(name)
            XCTAssertEqual(h.grants.compactMap { $0 }, [request])
            XCTAssertEqual(h.adapter.dispatchRequest(for: "call-1"), request)
            XCTAssertNil(h.adapter.dispatchRequest(for: "different-call"))
            try h.call(name)
            XCTAssertEqual(h.grants.count, 1, "Duplicate protocol events cannot emit another job")
            h.result()
            XCTAssertNil(h.adapter.dispatchRequest(for: "call-1"))
        }
    }

    func testFilingAndReadOnlySearchRemainAuthorizedAcrossSessionRestart() async throws {
        for _ in 0..<2 {
            for request in ["File this email in the Example Workspace project notes page.",
                            "Search Example Workspace for Project notes. Only find it; do not change anything."] {
                let h = Harness()
                try await h.start(request, desktop: true)
                try h.call()
                XCTAssertEqual(h.grants.compactMap { $0 }, [request])
                h.result()
                XCTAssertNil(h.adapter.dispatchRequest(for: "call-1"))
                h.adapter.close()
            }
        }
    }

    func testNewInputDesktopDismissalScopeChangeAndCloseInvalidatePendingGrant() async throws {
        for transition in ["input", "desktop", "scope", "close"] {
            let h = Harness(); defer { h.adapter.close() }
            try await h.start("Search Example Workspace without changing anything")
            try h.call()
            XCTAssertNotNil(h.adapter.dispatchRequest(for: "call-1"))
            switch transition {
            case "input": try h.input("Actually create a new page", time: 4_000)
            case "desktop": h.adapter.beginDesktopInteraction(origin: "selection", revision: 2)
            case "scope": h.scope = "profile-b"
            default: h.adapter.close()
            }
            XCTAssertNil(h.adapter.dispatchRequest(for: "call-1"), transition)
            if transition == "input" {
                try await h.settled()
                XCTAssertNil(h.adapter.dispatchRequest(for: "call-1"), "A clarification cannot broaden the original request")
            }
        }
    }

    func testFeedbackUnfinishedAndStaleRequestsNeverGrantDispatch() async throws {
        for request in ["Log feedback: the search failed", "Please forward to", "Search Example Workspace"] {
            let h = Harness(); defer { h.adapter.close() }
            try await h.start(request)
            if request == "Search Example Workspace" {
                try h.input("What is on my calendar?", time: 4_000)
                try await h.settled()
            }
            try h.call()
            XCTAssertTrue(h.grants.compactMap { $0 }.isEmpty, request)
        }
    }

    func testRoutedSavedCommandRetryKeepsOriginalRequestAfterLocalResolution() async throws {
        let h = Harness(); defer { h.adapter.close() }
        let request = "Retry that failed follow-up command"
        try h.receive(["type": "session.started"])
        try h.input(request); try await h.settled()
        XCTAssertTrue(h.adapter.beginFastAction(callId: "retry", action: nil, routed: true))
        h.adapter.resolveLocalInput(allowPresentation: false)
        XCTAssertEqual(h.adapter.dispatchRequest(for: "retry"), request)
        h.adapter.outbound(["type": "conversation.item.create", "item": ["type": "function_call_output", "call_id": "retry", "output": "Started."]])
        XCTAssertNil(h.adapter.dispatchRequest(for: "retry"))
    }
}
