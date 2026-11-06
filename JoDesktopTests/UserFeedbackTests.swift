import XCTest
@testable import CodenameJo

@MainActor
final class UserFeedbackTests: XCTestCase {
    private final class CaptureHarness: UserFeedback {
        var owner = Submission(userID: "user", context: .init(sessionID: UUID(), profileID: "work"))
        var saved: [(String, Submission)] = []
        var failSave = false
        override func capture() -> Submission { owner }
        override func save(_ message: String, source: FeedbackSource, submission: Submission) async throws -> UUID {
            if failSave { throw URLError(.cannotWriteToFile) }
            saved.append((message, submission))
            return UUID()
        }
    }

    func testSolicitedVoiceFeedbackCollectsFragmentsAndSavesOnceBeforeResumingFeed() async throws {
        let feedback = CaptureHarness()
        feedback.voiceSaveDelay = .milliseconds(80)
        var replies: [String] = [], phases: [String] = []
        func input(_ text: String, _ turn: String) -> Bool {
            feedback.voiceInput(text, turnID: turn, reply: { replies.append($0) }, transition: { phases.append($0) })
        }
        XCTAssertTrue(input("Yeah, just file some feedback.", "request"))
        XCTAssertEqual(replies, ["What would you like the feedback to say?"])
        XCTAssertTrue(input("Yeah, basically this weird error", "note"))
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(input("Yeah, basically this weird error of the inbox being too full", "note"))
        XCTAssertTrue(input("Uh, yeah, let's go through the feed", "resume"))
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(feedback.saved.map { $0.0 }, ["Yeah, basically this weird error of the inbox being too full"])
        XCTAssertEqual(feedback.saved.first?.1.context.profileID, "work")
        XCTAssertEqual(feedback.saved.first?.1.context.turnID, "request")
        XCTAssertEqual(phases.filter { $0 == "saved" }.count, 1)
        XCTAssertTrue(replies.last?.hasPrefix("Feedback saved") == true)
        XCTAssertTrue(input("Yeah, just file some feedback.", "request"))
        XCTAssertTrue(input("Yeah, basically this weird error of the inbox being too full", "note"))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(feedback.saved.count, 1)
    }

    func testVoiceFeedbackSurvivesSaveFailureAndTransfersToButtonWithoutAnotherSave() async throws {
        let feedback = CaptureHarness()
        feedback.voiceSaveDelay = .milliseconds(20)
        feedback.failSave = true
        var replies: [String] = []
        XCTAssertTrue(feedback.voiceInput("Log this feedback: audio failed", turnID: "note", reply: { replies.append($0) }, transition: { _ in }))
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(feedback.pendingVoiceText, "audio failed")
        XCTAssertTrue(replies.last?.contains("not saved") == true)
        feedback.failSave = false
        XCTAssertEqual(feedback.takeVoiceDraft(), "audio failed")
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertTrue(feedback.saved.isEmpty)
        XCTAssertNil(feedback.pendingVoiceText)
    }

    func testVoiceFeedbackCancelsAndDoesNotCrossProfileOrUserBoundaries() async throws {
        let feedback = CaptureHarness()
        feedback.voiceSaveDelay = .milliseconds(30)
        func input(_ text: String, _ turn: String) {
            _ = feedback.voiceInput(text, turnID: turn, reply: { _ in }, transition: { _ in })
        }
        input("record feedback: original note", "a")
        feedback.owner = .init(userID: "other", context: .init(profileID: "other-profile"))
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(feedback.saved.isEmpty)
        XCTAssertNil(feedback.pendingVoiceText)
        feedback.owner = .init(userID: "user", context: .init(sessionID: UUID(), profileID: "work"))
        XCTAssertEqual(feedback.pendingVoiceText, "original note", "Reconnect retains the original scoped draft")
        input("cancel feedback", "b")
        XCTAssertNil(feedback.pendingVoiceText)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(feedback.saved.isEmpty)
        XCTAssertNil(VoiceFeedbackText.request("don't log feedback"))
        XCTAssertNil(VoiceFeedbackText.request("read the feedback email"))
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }

    private func rows(_ data: Data) throws -> [[String: Any]] {
        try String(decoding: data, as: UTF8.self).split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }

    func testVoiceAndButtonFeedbackSurviveRelaunchWithTheirSessionContext() async throws {
        let folder = try directory()
        let log = VoiceDiagnostics(directory: folder)
        let conversation = UUID()
        let session = log.begin(conversationID: conversation, engine: "live", userID: "user-a")
        let context = FeedbackContext(sessionID: session.id, conversationID: conversation,
                                      profileID: "profile-a", engine: "live", state: "responding", turnID: "turn-a")
        let message = "The voice cut off.\nPlease let me finish — thanks! 🎙️"
        let id = try await log.saveFeedback(message, source: .button, userID: "user-a", context: context)
        let receipt = await UserFeedbackTool.run(argumentsJSON: #"{"message":"The next button is hard to find."}"#) {
            try await log.saveFeedback($0, source: .voice, userID: "user-a", context: context)
        }
        XCTAssertFalse(receipt.failed)
        let data = try await VoiceDiagnostics(directory: folder).snapshot(userID: "user-a")
        let entries = try rows(data)
        XCTAssertEqual(entries.filter { $0["event"] as? String != "sessionManifest" }.count, 3)
        let notes = entries.filter { $0["event"] as? String == "userFeedback" }
        XCTAssertEqual(notes.count, 2)
        XCTAssertEqual(notes[0]["feedback_id"] as? String, id.uuidString)
        XCTAssertEqual(notes[0]["message"] as? String, message)
        XCTAssertEqual(notes[0]["source"] as? String, "button")
        XCTAssertEqual(notes[1]["source"] as? String, "voice")
        XCTAssertEqual(notes[0]["session_id"] as? String, session.id.uuidString)
        XCTAssertEqual(notes[0]["conversation_id"] as? String, conversation.uuidString)
        XCTAssertEqual(notes[0]["profile_id"] as? String, "profile-a")
        XCTAssertEqual(notes[0]["turn_id"] as? String, "turn-a")
        XCTAssertEqual(notes[0]["user_id"] as? String, "user-a")
        XCTAssertEqual(notes[0]["engine"] as? String, "live")
        XCTAssertNotNil(notes[0]["timestamp"])
        XCTAssertNotNil(notes[0]["app_version"])
    }

    func testExportOnlyIncludesTheRequestedUsersFeedback() async throws {
        let folder = try directory()
        let log = VoiceDiagnostics(directory: folder)
        _ = try await log.saveFeedback("Alice's note", source: .button, userID: "alice", context: .init())
        _ = try await log.saveFeedback("Bob's note", source: .voice, userID: "bob", context: .init())
        let alice = try await log.snapshot(userID: "alice")
        XCTAssertEqual(try rows(alice).map { $0["message"] as? String }, ["Alice's note"])
        let anonymous = try await log.snapshot()
        XCTAssertTrue(anonymous.isEmpty)
        for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
    }

    func testEmptyAndOversizedFeedbackAreRejectedBeforeWriting() async throws {
        let folder = try directory()
        let log = VoiceDiagnostics(directory: folder)
        for message in [" \n\t ", String(repeating: "x", count: FeedbackText.maximumCharacters + 1)] {
            do {
                _ = try await log.saveFeedback(message, source: .button, userID: "user", context: .init())
                XCTFail("Invalid feedback was accepted")
            } catch { XCTAssertTrue(error is FeedbackError) }
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    func testToolDoesNotReportSuccessWhenTheDiskWriteFails() async throws {
        let blocked = try directory().appendingPathComponent("not-a-directory")
        try Data("existing file".utf8).write(to: blocked)
        let log = VoiceDiagnostics(directory: blocked)
        let result = await UserFeedbackTool.run(argumentsJSON: #"{"message":"Please save this bug report."}"#) {
            try await log.saveFeedback($0, source: .voice, userID: "user", context: .init())
        }
        XCTAssertTrue(result.failed)
        XCTAssertTrue(result.output.contains("NOT saved"))
        XCTAssertFalse(result.output.contains("Reference:"))
    }

    func testMalformedToolArgumentsDoNotWriteFeedback() async {
        var called = false
        for args in ["not json", "[]", "{}", #"{"message":42}"#, #"{"message":"  "}"#] {
            let result = await UserFeedbackTool.run(argumentsJSON: args) { _ in
                called = true
                return UUID()
            }
            XCTAssertTrue(result.failed)
        }
        XCTAssertFalse(called)
    }

    func testVoiceTrafficDoesNotRotateAwayUserFeedback() async throws {
        let folder = try directory()
        let log = VoiceDiagnostics(directory: folder, maximumBytes: 1_000)
        _ = try await log.saveFeedback("Keep this feedback", source: .button, userID: "user", context: .init())
        let session = log.begin(engine: "live")
        for _ in 0..<100 { session.record(.microphoneStarted) }
        let data = try await log.snapshot(userID: "user")
        let notes = try rows(data).filter { $0["event"] as? String == "userFeedback" }
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes.first?["message"] as? String, "Keep this feedback")
    }

    func testFeedbackRotationRetainsCompleteRecentNotes() async throws {
        let log = VoiceDiagnostics(directory: try directory(), maximumBytes: 1_000)
        for index in 0..<30 {
            _ = try await log.saveFeedback("Feedback \(index)", source: .button, userID: "user", context: .init())
        }
        let data = try await log.snapshot(userID: "user")
        let notes = try rows(data)
        XCTAssertLessThanOrEqual(data.count, 4_000)
        XCTAssertLessThan(notes.count, 30)
        XCTAssertEqual(notes.last?["message"] as? String, "Feedback 29")
    }

    func testFeedbackToolIsOfferedAndRoutedWithoutAConnector() throws {
        let name = UserFeedbackTool.name
        let tool = try XCTUnwrap(LiveSessionSetup.tools[name])
        XCTAssertEqual(tool.schema(.init())?["name"] as? String, name)
        let setup = LiveSessionSetup.resolve(.init(), .init(), catalog: .bundled)
        XCTAssertEqual(setup.tools.filter { $0["name"] as? String == name }.count, 1)
        let parameters = try XCTUnwrap(tool.schema(.init())?["parameters"] as? [String: Any])
        XCTAssertEqual(parameters["required"] as? [String], ["message"])
    }
}
