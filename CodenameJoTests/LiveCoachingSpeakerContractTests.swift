import XCTest
@testable import CodenameJo

final class LiveCoachingSpeakerContractTests: XCTestCase {
    private static func step(
        interactive: Bool = true,
        delivery: String? = "local_playback",
        capability: String = "voice_only"
    ) -> String {
        var coaching: [String: Any] = [
            "checkpoint": 1,
            "id": "owner@example.test|2026-09-16|1|page",
            "note": "Ask exactly `Hey, do you want to learn something new about Jo? You can say yes "
                + "or no.` and wait. Only after yes, speak lesson.speech exactly.",
            "lesson": [
                "capability": capability,
                "copy": "You never need to look at your phone with me.",
                "speech": "Quick tip: You never need to look at your phone with me. "
                    + "Was that helpful?",
                "answerInstruction": "Yes or no is feedback only.",
            ],
        ]
        if interactive { coaching["interactive"] = true }
        if let delivery { coaching["delivery"] = delivery }
        let payload: [String: Any] = ["done": false, "interstitial": "page", "coaching": coaching]
        return String(decoding: try! JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
    }

    func testTheSpeakerIsGivenTheInvitationAndNoneOfTheCheckpointsPolicy() throws {
        let brief = try XCTUnwrap(LiveCoachingSpeakerContract.invitation(step: Self.step()))
        XCTAssertEqual(brief, #"Say exactly this, then stop: "Hey, do you want to learn something new about Jo? You can say yes or no.""#)
        for leaked in ["coach_capability", "lesson.speech", "checkpoint", "triage_next", "Quick tip"] {
            XCTAssertFalse(brief.contains(leaked), leaked)
        }
    }

    /// A checkpoint reached by archive/draft/send arrives as a receipt with the queue JSON
    /// appended. Parsing the whole string as JSON reads that as no checkpoint at all.
    func testACheckpointBehindASpokenReceiptIsStillRead() throws {
        let behindReceipt = "Archived. That one's done.\n" + Self.step()
        XCTAssertEqual(LiveCoachingSpeakerContract.invitation(step: behindReceipt),
                       LiveCoachingSpeakerContract.invitation(step: Self.step()))
        XCTAssertEqual(LiveCoachingSpeakerContract.lessonSpeech(step: behindReceipt),
                       LiveCoachingSpeakerContract.lessonSpeech(step: Self.step()))
        XCTAssertEqual(LiveCoachingSpeakerContract.capability(step: behindReceipt),
                       "voice_only")
    }

    func testANonInteractiveCheckpointKeepsItsExistingWording() {
        XCTAssertNil(LiveCoachingSpeakerContract.invitation(step: Self.step(interactive: false)))
        XCTAssertNil(LiveCoachingSpeakerContract.invitation(step: #"{"done":false,"item":{"id":"a"}}"#))
        XCTAssertNil(LiveCoachingSpeakerContract.invitation(step: "not json"))
    }

    func testTheLessonIsReadBackVerbatimOnlyWhenItWasPreloaded() throws {
        XCTAssertEqual(try XCTUnwrap(LiveCoachingSpeakerContract.lessonSpeech(step: Self.step())),
                       "Quick tip: You never need to look at your phone with me. "
                           + "Was that helpful?")
        XCTAssertNil(LiveCoachingSpeakerContract.lessonSpeech(step: Self.step(delivery: nil)))
        XCTAssertNil(LiveCoachingSpeakerContract.lessonSpeech(step: Self.step(delivery: "hosted")))
        XCTAssertEqual(LiveCoachingSpeakerContract.capability(step: Self.step()), "voice_only")
    }

    func testAnAnswerIsItsFirstWordAndStaysShort() {
        for text in ["Yes", "yeah.", "Sure!", "okay", "Yeah, sure", "Uh, sure", "Um, yeah",
                     "Sure, why not", "Definitely", "alright then", "Well, okay"] {
            XCTAssertEqual(LiveCoachingAnswer.parse(text), .accepted, text)
        }
        for text in ["No", "nope.", "not now", "No, thanks", "Uh, no"] {
            XCTAssertEqual(LiveCoachingAnswer.parse(text), .declined, text)
        }
        // A request is not an answer, however it opens — and a sentence is not a bare answer.
        for text in ["yes archive this one", "no read it in full", "skip this email",
                     "yes send that draft", "yeah it is definitely really helpful",
                     "keep going through emails", "skip this email", "skip it", "maybe later",
                     "", "what?"] {
            XCTAssertNil(LiveCoachingAnswer.parse(text), text)
        }
    }

    /// Asking for the tip is a yes, whatever it opens with.
    func testAskingForTheTipIsAYes() {
        for text in ["You can tell me something new about Jo", "Tell me the tip", "Sure, tell me",
                     "go ahead", "Yes, go ahead", "Uh, teach me something new", "Give me the tip"] {
            XCTAssertEqual(LiveCoachingAnswer.parse(text), .accepted, text)
        }
        for text in ["Tell me about this email", "tell me the tip and archive this",
                     "Go through the next one", "keep going", "show me the new email",
                     "No, don't tell me", "not now, tell me later"] {
            XCTAssertNil(LiveCoachingAnswer.parse(text), text)
        }
    }

    /// The lesson marker is what moves the Feed on, and it must not depend on the parser having
    /// recognised the answer that preceded it.
    func testAGivenLessonIsRecognisedHoweverItIsIntroduced() {
        for spoken in ["Quick tip: you can turn an email into a calendar event.",
                       "Here's a quick tip: you can turn an email into a calendar event.",
                       "QUICK TIP: sure thing."] {
            XCTAssertNotNil(spoken.range(of: "quick tip", options: .caseInsensitive), spoken)
        }
        XCTAssertNil("Archived. What would you like to do with it?"
            .range(of: "quick tip", options: .caseInsensitive))
    }

    func testTheBackendOnlyBriefIsSilent() {
        XCTAssertEqual(LiveCoachingSpeakerContract.backendOnly, "")
    }

    func testARuleLessonIsRecognisedSoItsOwnYesStaysWithTheModel() {
        XCTAssertNotNil(StandingRule(rawValue: "archive_after_reply"))
        XCTAssertNil(StandingRule(rawValue: "voice_only"))
        XCTAssertNil(StandingRule(rawValue: "feed"))
    }
}
