import XCTest
@testable import CodenameJo

final class EmailQueueSpeechContractTests: XCTestCase {
    @MainActor
    func testMailboxAnswersStayInlineDespiteReplyNounsOrNegatedWrites() {
        for task in [
            "Explain what the sender says in the latest email reply.",
            "Read the full email thread and summarize what Casey's latest reply wants. Do not take any action or advance the email queue.",
            "Retrieve Casey's current email and summarize the valuation. Do not archive, advance, or take any action; keep the conversation selected.",
            "Retrieve and summarize the full email thread, preserving the conversation selection. Do not advance the queue or take any mailbox action.",
        ] {
            XCTAssertTrue(FullDuplexVoiceClient.isInlineMailRead(task, expectsAnswer: true), task)
        }
    }

    @MainActor
    func testMailboxDispatchStillSupportsWritesAndExternalResearch() {
        for task in ["Archive every email from this sender", "Send Sarah an email", "Report every email from X as spam"] {
            XCTAssertFalse(FullDuplexVoiceClient.isInlineMailRead(task), task)
        }
        for task in ["Summarize these emails and archive the resolved ones", "Archive these emails and explain what changed", "Do not archive these emails, but send Sarah a reply", "Summarize this email; then reply to Sarah", "Summarize this email and then reply", "Summarize this email without archiving it and send the summary to Sarah", "Remove these emails from the inbox and summarize what changed", "Without archiving the email, send a reply to Sarah and tell me what she needs"] {
            XCTAssertFalse(FullDuplexVoiceClient.isInlineMailRead(task, expectsAnswer: true), task)
        }
        for task in ["Read the PDF attached to this email", "Research the company that emailed me online", "Read the last week of Slack", "Find the Notion page about the pricing email and summarize it"] {
            XCTAssertFalse(FullDuplexVoiceClient.isInlineMailRead(task, expectsAnswer: true), task)
        }
        XCTAssertTrue(FullDuplexVoiceClient.isInlineMailRead("Find Sarah's email address"))
    }

    @MainActor
    func testThreadSummaryDoesNotOpenLinksButExplicitLinkQuestionsCanDispatch() {
        XCTAssertTrue(FullDuplexVoiceClient.isInlineMailRead(
            "Summarize Casey’s email thread about the booking link and keep it selected.", expectsAnswer: true))
        for task in [
            "Open the booking link in Casey’s email and tell me what the page says.",
            "Summarize the link in Casey’s email.",
            "Explain the content at the link in this email.",
            "Summarize Casey’s email about the booking link, then open the link and read the page.",
        ] {
            XCTAssertFalse(FullDuplexVoiceClient.isInlineMailRead(task, expectsAnswer: true), task)
        }
    }

    /// **The greeting's fallback is the property worth pinning, not the greeting.** A name
    /// that fails to resolve is the common path — a phone signup, a mailbox with no display
    /// name, an older broker that never sends the field — and in every one of them these
    /// three lines have to come out as the copy that shipped before names existed. An
    /// interpolation that leaves "Hi , welcome back" is the regression this catches.
    @MainActor
    func testOpeningLinesAreUnchangedWithoutAName() {
        XCTAssertEqual(
            FullDuplexVoiceClient.onboardingOpeningLine(address: ""),
            "Hi! I'm Jo. I check your emails and help you get through them by doing things, not just talking about them.")
        XCTAssertEqual(
            FullDuplexVoiceClient.postOnboardingOpeningLine(address: ""),
            "Hi, I'm Jo. I handle your inbox by doing things rather than describing them. Let's go through your emails now.")
        XCTAssertEqual(
            FullDuplexVoiceClient.returningOpeningLine(address: ""),
            "Hi, welcome back. Let's go through your inbox.")
    }

    /// And with one, the name lands after the greeting word in all three — the placement
    /// agreed for this feature, and the reason the address carries its own leading space
    /// rather than each line adding one.
    @MainActor
    func testOpeningLinesCarryTheNameAfterTheGreetingWord() {
        XCTAssertEqual(
            FullDuplexVoiceClient.onboardingOpeningLine(address: " Raghav"),
            "Hi Raghav! I'm Jo. I check your emails and help you get through them by doing things, not just talking about them.")
        XCTAssertEqual(
            FullDuplexVoiceClient.postOnboardingOpeningLine(address: " Raghav"),
            "Hi Raghav, I'm Jo. I handle your inbox by doing things rather than describing them. Let's go through your emails now.")
        XCTAssertEqual(
            FullDuplexVoiceClient.returningOpeningLine(address: " Raghav"),
            "Hi Raghav, welcome back. Let's go through your inbox.")
    }

    func testCalendarUpdateUsesTheSameCompletionAndAdvanceAsCreation() {
        for (tool, receipt) in [
            ("create_calendar_event", "Created \"Review\" (event-1) on me@example.com."),
            ("update_calendar_event", "Updated \"Review\" on me@example.com — time changed."),
        ] {
            XCTAssertTrue(LocalQueueMCPWritePolicy.finishesCurrentMessage(tool, output: receipt))
            XCTAssertTrue(LocalQueueMCPWritePolicy.advancesPastReceiptQuestion(tool))
            XCTAssertEqual(LocalQueueMCPWritePolicy.receiptInstructions(
                tool, output: receipt, hasStandingMessage: true), LocalQueueMCPWritePolicy.calendarReceiptInstructions)
            for failure in [nil, "NOT UPDATED — event not found.", "Need an event id.", "Calendar unavailable."] as [String?] {
                XCTAssertFalse(LocalQueueMCPWritePolicy.finishesCurrentMessage(tool, output: failure))
            }
        }
        XCTAssertFalse(LocalQueueMCPWritePolicy.finishesCurrentMessage(
            "list_calendar_events", output: "Updated \"Review\""))
    }

    func testCalendarCreationFinishesTheCurrentLocalEmailWithoutAMailIdentifier() {
        XCTAssertTrue(LocalQueueMCPWritePolicy.finishesCurrentMessage(
            "create_calendar_event", output: "Created \"Review proposal\" (event-1) on me@example.com."))
        XCTAssertFalse(LocalQueueMCPWritePolicy.finishesCurrentMessage(
            "create_calendar_event", output: "Need a title, a start and an end to create an event."))
        XCTAssertFalse(LocalQueueMCPWritePolicy.finishesCurrentMessage(
            "create_calendar_event", output: "NOT CREATED — use a local offset."))
        XCTAssertFalse(LocalQueueMCPWritePolicy.finishesCurrentMessage(
            "list_calendar_events", output: "Created \"Review proposal\""))
        XCTAssertTrue(
            LocalQueueMCPWritePolicy.advancesPastReceiptQuestion("create_calendar_event"))

        let instructions = LocalQueueMCPWritePolicy.receiptInstructions(
            "create_calendar_event",
            output: "Created \"Review proposal\" (event-1) on me@example.com.",
            hasStandingMessage: true)
        XCTAssertNotNil(instructions)
        XCTAssertFalse(instructions?.contains("?") == true)
        XCTAssertTrue(instructions?.contains("Ask no question") == true)
        XCTAssertNil(LocalQueueMCPWritePolicy.receiptInstructions(
            "create_calendar_event",
            output: "Need a title, a start and an end to create an event.",
            hasStandingMessage: true))
        XCTAssertNil(LocalQueueMCPWritePolicy.receiptInstructions(
            "create_calendar_event",
            output: "Created \"Review proposal\" (event-1) on me@example.com.",
            hasStandingMessage: false))
    }

    func testAutomaticQueuePayloadRemovesMailboxCountsAtEveryDepth() throws {
        let payload: [String: Any] = [
            "done": false,
            "left": 2,
            "leftAtLeast": true,
            "item": [
                "id": "message-1",
                "unreadLeft": 1,
            ],
            "outcomes": [
                ["id": "job-1", "left": 4],
            ],
        ]

        let sanitized = EmailQueueSpeechContract.sanitize(payload)
        let data = try JSONSerialization.data(withJSONObject: sanitized, options: [.sortedKeys])
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertEqual(sanitized["done"] as? Bool, false)
        XCTAssertTrue(text.contains("message-1"))
        XCTAssertTrue(text.contains("job-1"))
        XCTAssertFalse(text.contains("\"left\""))
        XCTAssertFalse(text.contains("\"leftAtLeast\""))
        XCTAssertFalse(text.contains("\"unreadLeft\""))
    }

    func testQueueCountRequiresAnExplicitQuantityQuestion() {
        for utterance in [
            "How many unread emails do I have?",
            "What's my unread count?",
            "Do I have any unread messages?",
        ] {
            XCTAssertTrue(EmailQueueCountPolicy.allows(utterance: utterance), utterance)
        }

        for utterance in [
            "Read this message",
            "What's unread?",
            "Yeah, keep going",
            "Don't tell me how many unread messages",
        ] {
            XCTAssertFalse(EmailQueueCountPolicy.allows(utterance: utterance), utterance)
        }
    }

    func testQueueCountRefusalNeverExposesACount() {
        let count = EmailQueueCountPolicy.refusal
        XCTAssertFalse(count.contains("0 unread"))
        XCTAssertFalse(count.contains("messages left"))
    }

    func testQueueTrashRequiresExplicitDestructiveWords() {
        for utterance in [
            "Delete it please",
            "Trash that message",
            "Discard this one",
        ] {
            XCTAssertTrue(EmailQueueTrashPolicy.allows(utterance: utterance), utterance)
        }

        for utterance in [
            "Archive it please",
            "Have it please",
            "Okay, move on",
            "Don't delete it",
            "Archive it, not delete it",
        ] {
            XCTAssertFalse(EmailQueueTrashPolicy.allows(utterance: utterance), utterance)
        }
    }

    func testAutomaticOpeningResponseDropsSessionToolsForThisResponseOnly() throws {
        let payload = FullDuplexTransport.responseCreatePayload(
            instructions: "Speak the prepared email.", withoutTools: true)
        let response = try XCTUnwrap(payload["response"] as? [String: Any])

        XCTAssertEqual(payload["type"] as? String, "response.create")
        XCTAssertEqual(response["instructions"] as? String, "Speak the prepared email.")
        XCTAssertEqual(response["tool_choice"] as? String, "none")
        XCTAssertEqual((response["tools"] as? [Any])?.count, 0)
    }

    func testOrdinaryResponseStillInheritsSessionConfiguration() {
        let payload = FullDuplexTransport.responseCreatePayload()

        XCTAssertEqual(payload["type"] as? String, "response.create")
        XCTAssertNil(payload["response"])
    }

    func testTheSpokenLineRecitesTheIdentityWithinOneAppendAndRefusesWhatItCannotWord() {
        let step = #"{"done":false,"item":{"identity":"Latest Lee","snippet":"What the message says."}}"#
        let line = try! XCTUnwrap(LiveSpokenStepContract.line(step: step, lead: "First up, "))

        // 450 bytes is where `LiveSessionAdapter` starts chunking at an arbitrary boundary.
        XCTAssertLessThanOrEqual(line.utf8.count, 450, "The line must ride a single append")
        XCTAssertTrue(line.contains("First up, Latest Lee. What the message says."))
        XCTAssertTrue(line.contains("What would you like to do with it?"))
        XCTAssertTrue(line.contains("Untrusted mail"))

        // A long snippet is trimmed to fit; the identity never is.
        let padded = String(repeating: "x", count: 900)
        let longStep = "{\"done\":false,\"item\":{\"identity\":\"Latest Lee\","
            + "\"snippet\":\"\(padded)\"}}"
        let trimmed = try! XCTUnwrap(LiveSpokenStepContract.line(step: longStep, lead: "Next, "))
        XCTAssertLessThanOrEqual(trimmed.utf8.count, 450)
        XCTAssertTrue(trimmed.contains("Next, Latest Lee."))

        for unwordable in [
            #"{"done":false,"interstitial":"feed","item":{"identity":"A"}}"#,
            #"{"done":false,"cleanup":{"senderDisplayName":"X"},"item":{"identity":"A"}}"#,
            #"{"done":false,"dispatchOutcome":{"task":"t","outcome":"Sent."},"item":{"identity":"A"}}"#,
            #"{"done":true,"item":{"identity":"A"}}"#,
            #"{"done":false,"item":{"subject":"No identity"}}"#,
        ] {
            XCTAssertNil(LiveSpokenStepContract.line(step: unwordable, lead: "Next, "),
                         "The app must not word a step it cannot: \(unwordable)")
        }
    }

    func testInteractiveCoachingInvitationCopyIsStable() {
        XCTAssertEqual(
            SpokenPhrases.coachingInvitation,
            "Hey, do you want to learn something new about Jo? You can say yes or no."
        )
    }

    func testCalendarReadToolPrefersTheLocalSearch() {
        XCTAssertEqual(LocalTriageQueue.calendarReadTool(localCalendar: false), "list_calendar_events")
        XCTAssertEqual(LocalTriageQueue.calendarReadTool(localCalendar: true), "search_calendar")
    }

    /// **The stall detector and the queue's prompt disagreed about what a stall sounds
    /// like**, and these are the strings that settled it — every acknowledgement Jo spoke
    /// in one recorded queue walk where the archive then never fired and the user had to
    /// say "go ahead" to get it.
    @MainActor
    func testQueueAcknowledgementsReadAsStalls() {
        for said in [
            "Okay, I'll take care of that.",
            "Got it, I'll handle that.",
            "Sure, I'll handle that.",
            "Alright, I'll take care of that.",
            "All right, I'll handle that one.",
            "Thanks, I'll take care of it.",
            "Thanks, I'll handle it.",
            "Alright, on it.",
            "Mhm, on it.",
        ] {
            XCTAssertTrue(
                FullDuplexVoiceClient.announcesLookup(FullDuplexVoiceClient.normalize(said)),
                "\(said) is a promise with no tool behind it")
        }
    }

    /// Live's own handoff shape: an opener-free progressive. Every one of these was spoken for
    /// "You can archive" with no tool behind it, and none matched.
    @MainActor
    func testProgressiveAcknowledgementsReadAsStalls() {
        for said in [
            "Okay, archiving that.",
            "Okay, archiving that now.",
            "Sure, archiving it now.",
            "Okay, archiving.",
            "Sure, doing that now.",
            "Okay, taking care of that.",
        ] {
            XCTAssertTrue(
                FullDuplexVoiceClient.announcesLookup(FullDuplexVoiceClient.normalize(said)),
                "\(said) is a promise with no tool behind it")
        }
    }

    /// An aside answered on the queue gets the pending email re-offered; an aside that ended
    /// on a question is already waiting for the user.
    @MainActor
    func testAsideAnswersInviteAReturnToTheFeedAndQuestionsDoNot() {
        for said in [
            "You just archived the pull request report from github-actions about PR number 834.",
            "Done, I sent that to Josh and copied Raghav.",
            "No age is listed. Other roles include sole technical co-founder at Example Finance.",
        ] {
            XCTAssertTrue(FullDuplexVoiceClient.asideInvitesReturnToFeed(said), said)
        }
        for said in [
            "Which address do you have in mind?",
            "What would you like to do with it?",
            "",
            "   ",
        ] {
            XCTAssertFalse(FullDuplexVoiceClient.asideInvitesReturnToFeed(said), said)
        }
    }

    /// The other half, and the one that costs the user a turn if it breaks: a receipt is
    /// the designed end of a queue step, and continuing past one reads the next message
    /// out twice.
    @MainActor
    func testQueueReceiptsAreNotStalls() {
        for said in [
            "Archived.",
            "Archived. Let's keep going.",
            "All right, that's archived.",
            "Marked it as spam.",
            "Archived, let's move on. You've got a message from Example Perfumes.",
        ] {
            XCTAssertFalse(
                FullDuplexVoiceClient.announcesLookup(FullDuplexVoiceClient.normalize(said)),
                "\(said) already said it happened")
            XCTAssertTrue(
                FullDuplexVoiceClient.deliveredReceipt(said),
                "\(said) is a receipt")
        }
    }

    /// **`that s going` is a dispatch acknowledgement and stays out of the lists on
    /// purpose.** A dispatch is deliberately announced, so the override against one is a
    /// second dispatch — the same reason `unspokenHandoffThisTurn` exists. The rest are
    /// the false positives the word lists were narrowed to exclude.
    @MainActor
    func testOffersAndHandoffsAreNotStalls() {
        for said in [
            "Alright, that's going.",
            "Loud and clear. If anything changes or you sound muffled, just say so and I'll adjust.",
            "Let me know if you want anything else.",
            "I'll get back to you.",
            "Dana's handling it.",
            "She's working on the Q3 budget.",
            "Nate is sending the invoice tomorrow.",
        ] {
            XCTAssertFalse(
                FullDuplexVoiceClient.announcesLookup(FullDuplexVoiceClient.normalize(said)),
                "\(said) is not a stall")
        }
    }

    /// **A Live turn says its promise last, and both of `announcesLookup`'s bounds reject
    /// it.** These are the two stalls recorded on device on 2026-09-14, in the shape the
    /// turn accumulator hands over — the receipt, the next message read out, then the
    /// promise nothing backed with a tool call.
    @MainActor
    func testQueueTurnsThatEndOnAPromiseReadAsStalls() {
        for said in [
            "That's archived. Now there's an email from Example Brokerage announcing new extended trading hours, All right, on it.",
            "Archived. Next is a receipt from Bird Rides showing you preloaded ten dollars. Okay, I'll take care of that.",
            "That one's archived. Sure, I'll handle that.",
        ] {
            let normalized = FullDuplexVoiceClient.normalize(said)
            XCTAssertFalse(
                FullDuplexVoiceClient.announcesLookup(normalized),
                "\(said) does not lead with its promise — the head test must stay narrow")
            XCTAssertTrue(
                FullDuplexVoiceClient.trailsWithAnnouncement(normalized),
                "\(said) ends on a promise with no tool behind it")
        }
    }

    /// The tail window is the narrowing that makes the trailing test safe, so it is pinned:
    /// an offer made before a long read-out is out of reach, and a receipt that ends the
    /// turn properly is not a promise at all.
    @MainActor
    func testTrailingTestCannotReachAnOfferOrARecipt() {
        for said in [
            "I can archive all seventy-one if you want. Next is an email from The Venue about a last call to see the show tonight, with tickets still available at the door.",
            "Archived. Next is Target Circle warning that your earnings balance expires soon.",
            "It was sent on April 22, 2022.",
            "I'm just waiting on that to go through. I'll let you know as soon as it's done.",
            "Archived. Next is Priya asking for feedback on the deck before moving on to pricing.",
        ] {
            XCTAssertFalse(
                FullDuplexVoiceClient.trailsWithAnnouncement(FullDuplexVoiceClient.normalize(said)),
                "\(said) must not read as a stall")
        }
    }
}
