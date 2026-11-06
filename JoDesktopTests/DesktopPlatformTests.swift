import XCTest
@testable import CodenameJo

final class DesktopPlatformTests: XCTestCase {
    func testViewingSlackWorkDoesNotAdvanceTheVoiceCursor() async {
        let queue = LocalSlackQueue()
        let items = ["C1", "C2"].map {
            SlackQueueSnapshot.Item(teamId: "T1", teamName: "Workspace", channelId: $0,
                withUserId: nil, label: $0, kind: "channel", unread: 1, more: false,
                messages: [], why: "Needs a reply")
        }
        await queue.start(.init(workspaces: ["Workspace"], total: 2, items: items,
            report: .init(workspacesUnavailable: nil, unchecked: 0, unreachable: 0,
                          readStateUnknown: 0, dmsUnavailable: nil, markUnavailable: nil)))
        let before = await queue.currentStep()
        let first = await queue.desktopPreparedItems()
        let second = await queue.desktopPreparedItems()
        let after = await queue.currentStep()
        XCTAssertEqual(first.map(\.channelId), ["C1", "C2"])
        XCTAssertEqual(first.map(\.channelId), second.map(\.channelId))
        XCTAssertEqual(before, after)
        _ = await queue.finish(tool: "slack_mark_read", input: ["channel_id": "C1"],
            written: true, channel: "C1", markedRead: true)
        let remaining = await queue.desktopPreparedItems()
        XCTAssertEqual(remaining.map(\.channelId), ["C2"])
        await queue.end()
        let ended = await queue.desktopPreparedItems()
        XCTAssertTrue(ended.isEmpty)
    }

    @MainActor func testMicrophoneStatusNeverClaimsToListenBeforeCaptureIsLive() {
        let model = DesktopWorkspaceModel()
        model.inSession = true
        model.state = .listening
        model.micLive = false
        XCTAssertEqual(model.status, "Connecting")
        model.micLive = true
        XCTAssertEqual(model.status, "Jo is listening")
        model.muted = true
        XCTAssertEqual(model.status, "Microphone muted")
        model.state = .error("Disconnected")
        XCTAssertEqual(model.status, "Connection needs attention")
    }

    @MainActor func testBackgroundWorkPreservesCancellationOnMac() async {
        let task = Task {
            await HangUpRunway.run("Test cancelled local work") { Task.isCancelled }
        }
        task.cancel()
        let cancelled = await task.value
        XCTAssertTrue(cancelled)
    }

    @MainActor func testMacLocalFallbackOffersOnlyTheInstalledSystemVoice() {
        XCTAssertEqual(LocalVoice.allCases, [.system])
        XCTAssertEqual(LocalVoice.current, .system)
        XCTAssertFalse(LiveVoiceActivity.isAvailable)
        XCTAssertFalse(CarPlayPresence.isConnected)
    }
}
