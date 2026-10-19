import XCTest
@testable import CodenameJo

final class LiveFastActionTests: XCTestCase {
    func testFastDeleteRequiresOneExplicitCurrentMessageCommand() {
        for text in ["delete it", "please delete this email", "trash that", "move it to trash"] {
            XCTAssertEqual(LiveFastAction.parse(text), .trash)
            XCTAssertTrue(EmailQueueTrashPolicy.allows(utterance: text))
        }
        for text in ["don't delete it", "delete all", "delete the previous email", "delete it and reply",
                     "if I say delete it", "delete that?", "the email says delete it", "delete it actually no"] {
            XCTAssertNil(LiveFastAction.parse(text), text)
        }
    }

    func testOnlyWholeExplicitCommandsMatch() {
        for text in ["Archive.", "archive this email", "please archive it", "archive that please!"] {
            XCTAssertNil(LiveFastAction.parse(text), text)
        }
        for text in ["Next.", "next email", "go next", "skip this email"] {
            XCTAssertEqual(LiveFastAction.parse(text), .next, text)
        }
        for text in ["don't archive", "archive this but don't advance", "archive all", "archive all from them",
                     "archive this?", "archive this, actually no", "archive then reply",
                     "the email says archive this", "\"archive this\"", "next week", "yes", "keep going",
                     "skip the tip", "archive the previous email", "archive that and next", ""] {
            XCTAssertNil(LiveFastAction.parse(text), text)
        }
    }

    func testArchivePhrasesAlwaysNeedDelegation() {
        for text in ["Archive this one for me, please", "You can archive this one as well",
                     "Awesome. Can you archive this one for me, please",
                     "Can you archive it for me, please", "Please archive it for me",
                     "Can you please archive this email", "Could you archive this email?",
                     "Would you archive this one for me?", "can you archive this"] {
            XCTAssertNil(LiveFastAction.parse(text), text)
        }
    }

    func testPolitenessNeverRemovesConditionsCorrectionsOrOtherTargets() {
        for text in ["Can you archive this if it is spam?", "Please don't archive it for me",
                     "Awesome. Can you archive this one, actually no",
                     "Can you archive this and reply for me", "Could you archive the previous email?",
                     "Thanks. The email says archive this", "Can you archive all of these?",
                     "Remind me to archive this one", "If I say please archive this one",
                     "Archive this one?", "You can archive this one?", "Can you not archive this?"] {
            XCTAssertNil(LiveFastAction.parse(text), text)
        }
    }

    func testIdentityProfileAndRevisionMustRemainPinned() throws {
        let step = #"{"done":false,"item":{"id":"a","threadId":"t","account":"owner@example.test"}}"#
        let key = try XCTUnwrap(LiveEmailPresentation.Key.step(step))
        let anchor = LiveFastAction.Anchor(key: key, profileId: "personal", revision: 4)
        XCTAssertTrue(anchor.matches(step: step, profileId: "personal", revision: 4))
        XCTAssertFalse(anchor.matches(step: step, profileId: "work", revision: 4))
        XCTAssertFalse(anchor.matches(step: step, profileId: "personal", revision: 5))
        XCTAssertFalse(anchor.matches(step: step.replacingOccurrences(of: "\"a\"", with: "\"b\""), profileId: "personal", revision: 4))
        XCTAssertFalse(anchor.matches(step: nil, profileId: "personal", revision: 4))
        XCTAssertFalse(anchor.matches(step: step, profileId: nil, revision: 4))
    }

    func testConversationalWrappersStillRequireOneExplicitAction() {
        for text in ["You can archive", "Can archive", "We can archive it", "Just archive it",
                     "Then you can just archive", "I think we can just archive it", "Okay, archive."] {
            XCTAssertNil(LiveFastAction.parse(text), text)
        }
        for text in ["Okay, next", "Yeah, let's go to next", "Go ahead and skip this email"] {
            XCTAssertEqual(LiveFastAction.parse(text), .next, text)
        }
        for text in ["You can archive it and reply", "Okay, don't archive", "You can archive?",
                     "We can archive all", "skip it all", "Sure, archive the previous email",
                     "Then you can just archive, actually no"] {
            XCTAssertNil(LiveFastAction.parse(text), text)
        }
    }
    func testFastFollowupReadsArePinnedToTheNewEmailAndAccount() {
        let step = #"{"done":false,"item":{"id":"b","threadId":"tb","account":"owner@example.test"}}"#
        XCTAssertTrue(LiveFastAction.allowsFollowup(name: "gmail_get_message", arguments: #"{"id":"b","account":"owner@example.test"}"#, step: step))
        XCTAssertFalse(LiveFastAction.allowsFollowup(name: "gmail_get_message", arguments: #"{"id":"a","account":"owner@example.test"}"#, step: step))
        XCTAssertFalse(LiveFastAction.allowsFollowup(name: "gmail_get_message", arguments: #"{"id":"b","account":"other@example.test"}"#, step: step))
        XCTAssertFalse(LiveFastAction.allowsFollowup(name: "gmail_get_message", arguments: #"{"id":"b"}"#, step: step))
        XCTAssertFalse(LiveFastAction.allowsFollowup(name: "gmail_get_thread", arguments: #"{"id":"ta","account":"owner@example.test"}"#, step: step))
        XCTAssertFalse(LiveFastAction.allowsFollowup(name: "gmail_get_thread", arguments: #"{"id":"tb","account":"owner@example.test"}"#, step: step.replacingOccurrences(of: "\"id\":\"b\"", with: "\"exchangeId\":\"chain\",\"id\":\"b\"")))
        XCTAssertFalse(LiveFastAction.allowsFollowup(name: "archive_message", arguments: "{}", step: step))
    }
    func testARuleSwitchSurvivesAQueueAdvanceInTheSameTurnButWritesDoNot() {
        let step = #"{"done":false,"item":{"id":"b","threadId":"tb","account":"owner@example.test"}}"#
        XCTAssertTrue(LiveFastAction.allowsFollowup(name: "set_rule", arguments: #"{"rule":"archive_after_reply","enabled":true}"#, step: step))
        XCTAssertTrue(LiveFastAction.allowsFollowup(name: "set_rule", arguments: "{}", step: nil))
        for write in ["archive_message", "send_email", "unarchive_message", "dispatch", "triage_next"] {
            XCTAssertFalse(LiveFastAction.feedIndependent.contains(write), write)
            XCTAssertFalse(LiveFastAction.allowsFollowup(name: write, arguments: "{}", step: step), write)
        }
    }

}
