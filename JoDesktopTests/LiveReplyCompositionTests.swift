import XCTest
@testable import CodenameJo

@MainActor
final class LiveReplyCompositionTests: XCTestCase {
    private let source = #"{"done":false,"item":{"id":"A","threadId":"thread-A","account":"owner@example.test","subject":"Coffee"}}"#
    private let other = #"{"done":false,"item":{"id":"B","threadId":"thread-B","account":"other@example.test"}}"#
    private let dictation = "Reply thanking them for an insightful call. Suggest coffee or another call, and share https://example.test/weekly which happens every Tuesday."

    func testTargetClarificationRetainsCompleteDictationAndLaterFragments() throws {
        var reply = LiveReplyComposition(source: try XCTUnwrap(DispatchJob.MailOrigin.captured(in: source)),
            selection: source, request: dictation, turn: 1)
        reply.question("Which email did you mean? You mentioned a young woman.")
        XCTAssertTrue(reply.holdsDecision)
        reply.user("No, that's the one. I'm not mentioning a young woman.", turn: 2, selection: source)
        XCTAssertTrue(reply.targetConfirmed)
        reply.user("Reply saying thanks and tell them it happens every…", turn: 3, selection: source)
        XCTAssertEqual(reply.request, dictation)
        XCTAssertTrue(GmailReadTools.json(reply.context).contains("Tuesday"))
        XCTAssertTrue(GmailReadTools.json(reply.context).contains("https://example.test/weekly"))
        XCTAssertNil(reply.refusal(name: "reply_email", arguments: #"{"account":"owner@example.test","thread_id":"thread-A"}"#, selection: source))
        reply.question("Which email did you mean?")
        XCTAssertTrue(reply.targetConfirmed, "Repeating a resolved question cannot erase the confirmation")
    }

    func testNamedPriorSourcesRequireAccountClarificationWhenSubjectsRepeat() throws {
        let sameSubject = other.replacingOccurrences(of: "other@example.test\"", with: "other@example.test\",\"subject\":\"Coffee\"")
        let matches = LiveReplyComposition.namedSources("Reply to the Coffee email", recent: [source, sameSubject])
        XCTAssertEqual(matches.count, 2)
        XCTAssertEqual(LiveReplyComposition.namedSources("Reply to the Coffee email in owner@example.test", recent: matches), [source])
        var reply = LiveReplyComposition(source: try XCTUnwrap(DispatchJob.MailOrigin.captured(in: source)),
            selection: source, request: dictation, turn: 1)
        reply.candidateSelections = matches
        reply.clarification = "Which account's Coffee email?"
        reply.recoveredBody = dictation
        XCTAssertNotNil(reply.refusal(name: "send_email", arguments: "{}", selection: source))
        reply.user("Retry the reply", turn: 2, selection: sameSubject)
        XCTAssertTrue(reply.targetConfirmed)
        XCTAssertEqual(reply.source.account, "other@example.test")
        XCTAssertEqual(reply.recoveredBody, dictation)
        XCTAssertNil(reply.refusal(name: "send_email", arguments: #"{"account":"other@example.test","thread_id":"thread-B","reply_message_id":"B"}"#, selection: sameSubject))
    }

    func testUnavailableNamedSourceRequiresExplicitSelectionWithoutLosingText() throws {
        XCTAssertTrue(LiveReplyComposition.namesPriorSource("Reply to the Project check-in email: yes"))
        XCTAssertFalse(LiveReplyComposition.namesPriorSource("Reply to this email saying yes"))
        var reply = LiveReplyComposition(source: try XCTUnwrap(DispatchJob.MailOrigin.captured(in: source)),
            selection: source, request: dictation, turn: 1)
        reply.needsSourceSelection = true
        reply.clarification = "Which exact email?"
        reply.recoveredBody = dictation
        XCTAssertNotNil(reply.refusal(name: "send_email", arguments: "{}", selection: source))
        XCTAssertEqual(reply.context["original_source"] as? String, "")
        reply.user("Retry the reply", turn: 2, selection: other)
        XCTAssertFalse(reply.needsSourceSelection)
        XCTAssertTrue(reply.targetConfirmed)
        XCTAssertEqual(reply.source.messageID, "B")
        XCTAssertEqual(reply.recoveredBody, dictation)
    }

    func testDifferentSelectionAndUnknownWriteCannotRetargetOrRepeatComposition() throws {
        var reply = LiveReplyComposition(source: try XCTUnwrap(DispatchJob.MailOrigin.captured(in: source)),
            selection: source, request: dictation, turn: 1)
        reply.question("Which recipient did you mean?")
        reply.user("Yes, that one", turn: 2, selection: other)
        XCTAssertFalse(reply.targetConfirmed)
        XCTAssertNotNil(reply.refusal(name: "send_email", arguments: #"{"account":"other@example.test","thread_id":"thread-B"}"#, selection: other))
        reply.user("Yes, that one", turn: 3, selection: source)
        reply.user("Use a different recipient instead", turn: 4, selection: source)
        XCTAssertFalse(reply.targetConfirmed)
        reply.user("Yes, that one", turn: 5, selection: source)
        reply.writeCall = "uncertain-send"
        XCTAssertNotNil(reply.refusal(name: "send_email", arguments: #"{"account":"owner@example.test","thread_id":"thread-A"}"#, selection: source))
        XCTAssertEqual(reply.writeCall, "uncertain-send")
        XCTAssertTrue(LiveReplyComposition.cancels("Start over"))
        XCTAssertTrue(LiveReplyComposition.cancels("Cancel that reply"))
        XCTAssertFalse(LiveReplyComposition.requestsReply("a young woman"))
    }
}
