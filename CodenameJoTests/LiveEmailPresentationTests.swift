import XCTest
@testable import CodenameJo

final class LiveEmailPresentationTests: XCTestCase {
    private var savedSuggestionOverride: Any?
    private var savedAccountDefault: Any?

    override func setUp() {
        super.setUp()
        savedSuggestionOverride = UserDefaults.standard.object(forKey: SuggestedActions.storageKey)
        savedAccountDefault = UserDefaults.standard.object(forKey: SuggestedActions.accountDefaultKey)
        UserDefaults.standard.set(true, forKey: SuggestedActions.storageKey)
    }

    override func tearDown() {
        UserDefaults.standard.set(savedSuggestionOverride, forKey: SuggestedActions.storageKey)
        UserDefaults.standard.set(savedAccountDefault, forKey: SuggestedActions.accountDefaultKey)
        super.tearDown()
    }

    func testBrainSuggestionIsSpokenAsWritten() throws {
        let key = try XCTUnwrap(LiveEmailPresentation.Key.step(step))
        let value = LiveEmailPresentation(key: key, summary: "Maya wants to meet Tuesday at 1.", from: "Maya",
            to: key.account, sentAt: "2026-09-23T00:00:00Z",
            suggestedQuestion: "Want me to find a time?")
        XCTAssertEqual(value.suggestionForSpeech(enabled: true), value.suggestedQuestion)
        XCTAssertNil(value.suggestionForSpeech(enabled: false))
    }

    func testPreparationTimingPreservesOriginalReceiptAcrossCacheSeeding() throws {
        let key = try XCTUnwrap(LiveEmailPresentation.Key.step(step))
        let received = Date(timeIntervalSince1970: 1_000)
        var value = LiveEmailPresentation(key: key, summary: "Meeting request", from: "Alex",
                                         to: key.account, sentAt: "2026-09-23T00:00:00Z")
        XCTAssertFalse(value.timing(at: received).ready)
        XCTAssertNil(value.timing(at: received).leadMs)
        value.preparationReceivedAt = received
        value.preparationRequestId = "request-1"
        var cache = LiveEmailPreparationCache(profileId: "work")
        cache.seed([value], now: received.addingTimeInterval(10))
        let warmed = try XCTUnwrap(cache.ready(for: step, profileId: "work", now: received.addingTimeInterval(12)))
        XCTAssertEqual(warmed.preparationRequestId, "request-1")
        XCTAssertTrue(warmed.timing(at: received.addingTimeInterval(12)).ready)
        XCTAssertEqual(warmed.timing(at: received.addingTimeInterval(12)).leadMs, 12_000)
        XCTAssertFalse(warmed.timing(at: received.addingTimeInterval(-1)).ready)
        XCTAssertEqual(warmed.timing(at: received.addingTimeInterval(-1)).leadMs, -1_000)
    }

    func testSuggestionTimingEligibilityUsesPresentationLengthAndFlagRules() throws {
        let key = try XCTUnwrap(LiveEmailPresentation.Key.step(step))
        var value = LiveEmailPresentation(key: key, summary: "Meeting request", from: "Alex",
            to: key.account, sentAt: "2026-09-23T00:00:00Z", suggestedQuestion: "Should I book it?")
        XCTAssertNotNil(value.suggestionForSpeech(enabled: true))
        XCTAssertNil(value.suggestionForSpeech(enabled: false))
        value.suggestedQuestion = String(repeating: "x", count: 311)
        XCTAssertNil(value.suggestionForSpeech(enabled: true))
    }

    func testNewCurrentInvitationIsPreparedEvenWithoutAnyReadAheadItems() throws {
        let current = try XCTUnwrap(LiveEmailPresentation.Key.step(step))
        XCTAssertEqual(LiveEmailPreparationCache.candidates(current: step, readAhead: []), [current])
        let later = try XCTUnwrap(LiveEmailPresentation.Key.step(step.replacingOccurrences(of: "new", with: "later")))
        XCTAssertEqual(LiveEmailPreparationCache.candidates(current: step, readAhead: [later, current]), [current, later])
        XCTAssertEqual(LiveEmailPreparationCache.candidates(current: #"{"done":true}"#, readAhead: []), [])
    }

    func testAccountDefaultAndExplicitProfileOverride() {
        UserDefaults.standard.removeObject(forKey: SuggestedActions.storageKey)
        UserDefaults.standard.removeObject(forKey: SuggestedActions.accountDefaultKey)
        XCTAssertTrue(SuggestedActions.isEnabled)
        UserDefaults.standard.set(false, forKey: SuggestedActions.accountDefaultKey)
        XCTAssertFalse(SuggestedActions.isEnabled)
        UserDefaults.standard.set(true, forKey: SuggestedActions.accountDefaultKey)
        XCTAssertTrue(SuggestedActions.isEnabled)
        UserDefaults.standard.set(false, forKey: SuggestedActions.storageKey)
        XCTAssertFalse(SuggestedActions.isEnabled)
        XCTAssertEqual(UserProfile.capturingLocalSettings().suggestedActions, false)
        UserDefaults.standard.removeObject(forKey: SuggestedActions.storageKey)
        XCTAssertTrue(SuggestedActions.isEnabled)
    }

    func testDisablingHidesAlreadyPreparedSuggestion() throws {
        let key = try XCTUnwrap(LiveEmailPresentation.Key.step(step))
        let prepared = LiveEmailPresentation(key: key, summary: "Maya asks for a meeting.",
            from: "Maya", to: key.account, sentAt: "2026-09-22T15:00:00Z",
            suggestedQuestion: "Want me to find a time?")
        XCTAssertTrue(try XCTUnwrap(prepared.annotating(step)).contains("find a time"))
        UserDefaults.standard.set(false, forKey: SuggestedActions.storageKey)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(prepared.annotating(step)).utf8)) as? [String: Any])
        let item = try XCTUnwrap(payload["item"] as? [String: Any])
        XCTAssertNil(item["suggestedQuestion"])
        XCTAssertEqual(item["bodySummary"] as? String, prepared.summary)
    }

    private let step = #"{"done":false,"item":{"account":"owner@example.test","id":"new","threadId":"thread","from":"Alex","subject":"Budget","identity":"Alex","date":"today","snippet":"preview"}}"#

    @MainActor
    func testSuggestedActionReceiptDoesNotTriggerGenericReofferAfterCacheExpiry() throws {
        let key = try XCTUnwrap(LiveEmailPresentation.Key.step(step))
        let prepared = LiveEmailPresentation(key: key, summary: "Josh asks to meet.",
            from: "Josh", to: key.account, sentAt: "2026-09-22T15:00:00Z",
            suggestedQuestion: "Wednesday at 10 is free. Should I reschedule it?")
        var cache = LiveEmailPreparationCache(profileId: "work")
        cache.seed([prepared], now: Date().addingTimeInterval(-600))
        XCTAssertNil(cache.ready(for: step, profileId: "work"))
        XCTAssertTrue(cache.hasSuggestion(for: step, profileId: "work"))
        XCTAssertFalse(FullDuplexVoiceClient.asideInvitesReturnToFeed(
            "Done, I rescheduled your meeting.",
            hasSuggestion: cache.hasSuggestion(for: step, profileId: "work")))
        XCTAssertFalse(cache.hasSuggestion(for: step, profileId: "personal"))
        XCTAssertFalse(cache.hasSuggestion(for: step.replacingOccurrences(of: "new", with: "next"), profileId: "work"))
        XCTAssertFalse(cache.hasSuggestion(for: step.replacingOccurrences(of: "owner@example.test", with: "other@example.test"), profileId: "work"))
        UserDefaults.standard.set(false, forKey: SuggestedActions.storageKey)
        XCTAssertFalse(cache.hasSuggestion(for: step, profileId: "work"))
    }

    func testLocalHeadersOnlyVetoOverridesOlderServerPreference() async throws {
        let prior = UserDefaults.standard.object(forKey: MailHeadersOnly.storageKey)
        defer { UserDefaults.standard.set(prior, forKey: MailHeadersOnly.storageKey) }
        UserDefaults.standard.set(true, forKey: MailHeadersOnly.storageKey)
        let key = try XCTUnwrap(LiveEmailPresentation.Key.step(step))
        let result = await FullDuplexBroker.prepareEmail(key,
            scope: .init(profileId: "work", isDefault: false, emails: [key.account], mailHeadersOnly: false))
        XCTAssertNil(result)
    }

    func testPreparationRejectsUnrestoredAndWrongMailboxScopes() async throws {
        let key = try XCTUnwrap(LiveEmailPresentation.Key.step(step))
        for scope in [nil,
            .init(profileId: "work", isDefault: false),
            .init(profileId: "personal", isDefault: true, emails: ["personal@example.test"])] as [ProfileRuntime.Scope?] {
            let result = await FullDuplexBroker.prepareEmail(key, scope: scope)
            XCTAssertNil(result)
        }
    }

    func testBothProfilesWarmWithTheirOwnScopeAndKeepResultsIsolated() async throws {
        defer { ProfileRuntime.install(nil) }
        let workStep = step
        let personalStep = step.replacingOccurrences(of: "owner@example.test", with: "personal@example.test")
        let workKey = try XCTUnwrap(LiveEmailPresentation.Key.step(workStep))
        let personalKey = try XCTUnwrap(LiveEmailPresentation.Key.step(personalStep))
        let work = ProfileRuntime.Scope(profileId: "work", isDefault: false, emails: [workKey.account])
        let personal = ProfileRuntime.Scope(profileId: "personal", isDefault: true, emails: [personalKey.account])
        let store = LiveEmailOpeningSummary { key, scope in
            XCTAssertTrue(scope?.containsMailbox(key.account) == true)
            XCTAssertEqual(scope?.profileId, key.account == workKey.account ? "work" : "personal")
            return LiveEmailPresentation(key: key, summary: "Prepared for " + (scope?.profileId ?? "missing"),
                from: "Alex", to: key.account, sentAt: "2026-09-22T15:00:00Z")
        }
        ProfileRuntime.install(work)
        await store.warm([workKey], scope: work, userId: "owner")
        await store.warm([personalKey], scope: personal, userId: "owner")
        ProfileRuntime.install(personal)
        await store.awaitWarm()
        let workResult = await store.ready(for: workStep, profileId: "work", userId: "owner")
        let personalResult = await store.ready(for: personalStep, profileId: "personal", userId: "owner")
        let wrongProfile = await store.ready(for: workStep, profileId: "personal", userId: "owner")
        let wrongUser = await store.ready(for: workStep, profileId: "work", userId: "other-owner")
        XCTAssertEqual(workResult?.summary, "Prepared for work")
        XCTAssertEqual(personalResult?.summary, "Prepared for personal")
        XCTAssertNil(wrongProfile)
        XCTAssertNil(wrongUser)
    }

    func testStandaloneAndReplyChainKeysMatchQueueCandidates() throws {
        let single = LocalTriageQueue.Item(account: "owner@example.test", id: "new", threadId: "thread",
            from: "Alex", subject: "Budget", date: "today", snippet: "preview", internalDate: 2, acted: nil)
        XCTAssertEqual(LiveEmailPresentation.Key.item(single), LiveEmailPresentation.Key.step(step))
        var chain = single
        chain.displayGroupID = "reply-a"
        chain.exchangeContext = [.init(id: "old", from: "Owner", subject: "Budget", date: "yesterday",
            snippet: "Old budget", internalDate: 1)]
        let grouped = step.replacingOccurrences(of: #""snippet":"preview""#,
            with: #""snippet":"preview","exchangeId":"reply-a","exchangeContext":[{"id":"old"}]"#)
        XCTAssertEqual(LiveEmailPresentation.Key.item(chain), LiveEmailPresentation.Key.step(grouped))
        XCTAssertNotEqual(LiveEmailPresentation.Key.item(chain), LiveEmailPresentation.Key.item(single))
    }

    func testSpecialPresentationsNeverUseOrdinaryEmailSpeech() {
        for field in ["interstitial", "cleanup", "onboarding", "coaching", "dispatchOutcome", "presentedForOutcome"] {
            let special = step.replacingOccurrences(of: #""done":false"#, with: #""done":false,"\#(field)":{}"#)
            XCTAssertNil(LiveEmailPresentation.Key.step(special), field)
        }
        XCTAssertNil(LiveEmailPresentation.Key.step(step.replacingOccurrences(of: #""snippet":"preview""#,
            with: #""snippet":"preview","hasDraft":true"#)))
    }

    func testCacheRejectsOtherAccountsProfilesChainsAndExpiredEntries() throws {
        let key = try XCTUnwrap(LiveEmailPresentation.Key.step(step))
        let prepared = LiveEmailPresentation(key: key, summary: "Please approve $50 by Friday.",
            from: "Alex <alex@example.test>", to: "Owner <owner@example.test>", sentAt: "2026-09-15T15:00:00.000Z")
        let now = Date()
        var cache = LiveEmailPreparationCache(profileId: "personal")
        cache.entries[key.identity] = (prepared, now)
        XCTAssertNotNil(cache.ready(for: step, profileId: "personal", now: now))
        XCTAssertNil(cache.ready(for: step, profileId: "work", now: now))
        XCTAssertNil(cache.ready(for: step.replacingOccurrences(of: "owner@example.test", with: "other@example.test"), profileId: "personal", now: now))
        XCTAssertNil(cache.ready(for: step.replacingOccurrences(of: #""id":"new""#, with: #""id":"different""#), profileId: "personal", now: now))
        XCTAssertNil(cache.ready(for: step, profileId: "personal", now: now.addingTimeInterval(301)))
        XCTAssertNotNil(prepared.speakerLine(for: step))
        XCTAssertTrue(prepared.speakerLine(for: step)?.contains("$50") == true)
        XCTAssertFalse(prepared.speakerLine(for: step)?.contains("Archived") == true)
    }

    func testThreadGuidanceSurvivesCachedSummaryAndKeepsDirectSpeech() throws {
        let threaded = step.replacingOccurrences(of: #""done":false"#,
            with: #""done":false,"thread":{"note":"Still the same thread. This was requeued for a decision."}"#)
        let key = try XCTUnwrap(LiveEmailPresentation.Key.step(threaded))
        let prepared = LiveEmailPresentation(key: key, summary: "Please approve $50 by Friday.",
            from: "Alex <alex@example.test>", to: "Owner <owner@example.test>", sentAt: "2026-09-15T15:00:00.000Z")
        XCTAssertTrue(try XCTUnwrap(prepared.speakerLine(for: threaded)).contains("$50"))
        let annotated = try XCTUnwrap(prepared.annotating(threaded))
        XCTAssertTrue(annotated.contains("requeued for a decision"))
        XCTAssertTrue(annotated.contains("bodySummary"))
        XCTAssertTrue(annotated.contains("$50"))
    }

    func testThreadOpeningKeepsPreparedConversationAndQuestion() throws {
        let threaded = step.replacingOccurrences(of: #""done":false"#,
            with: #""done":false,"thread":{"note":"Requeued for a decision."}"#)
        let key = try XCTUnwrap(LiveEmailPresentation.Key.step(threaded))
        let prepared = LiveEmailPresentation(key: key,
            summary: "Alex revised the budget after your feedback and now needs approval.",
            from: "Alex", to: "Owner", sentAt: "2026-09-15T15:00:00.000Z",
            suggestedQuestion: "Tue Sep 29 at 2pm PT is free for 30 min. Should I book it?")
        let line = try XCTUnwrap(LiveSpokenStepContract.line(
            step: threaded, lead: "First up, ", prepared: prepared))
        XCTAssertTrue(line.contains(prepared.summary))
        XCTAssertTrue(line.contains(try XCTUnwrap(prepared.suggestedQuestion)))
        XCTAssertFalse(line.contains("preview"))
        let advance = try XCTUnwrap(LiveSpokenStepContract.line(
            step: threaded, lead: "Next, ", prepared: prepared))
        XCTAssertTrue(advance.contains(prepared.summary))
        XCTAssertTrue(advance.contains(try XCTUnwrap(prepared.suggestedQuestion)))
        XCTAssertTrue(try XCTUnwrap(prepared.annotating(threaded)).contains("Requeued for a decision."))
    }

    func testAScriptIsOfferedOnlyWhereItWouldNotBeSuperseded() throws {
        let key = try XCTUnwrap(LiveEmailPresentation.Key.step(step))
        let prepared = LiveEmailPresentation(key: key, summary: "Alex wants the budget approved.",
            from: "Alex <alex@example.test>", to: "Owner <owner@example.test>",
            sentAt: "2026-09-15T15:00:00.000Z")
        let script = try XCTUnwrap(FullDuplexVoiceClient.presentableScript(
            step: step, lead: "Next, ", prepared: prepared))
        XCTAssertTrue(script.contains("Next, Alex wants the budget approved."))
        XCTAssertFalse(script.contains("Budget"), "The subject is never announced ahead of the summary")

        // No prepared summary leaves the body half as the sender's own snippet, which is the
        // backend's to summarise — so the caller keeps its composition instructions.
        XCTAssertNil(FullDuplexVoiceClient.presentableScript(
            step: step, lead: "Next, ", prepared: nil))

        // Cleanup keeps its own offer; a prepared thread keeps its closing question.
        let cleanup = step.replacingOccurrences(of: #""done":false"#,
            with: #""done":false,"cleanup":{"senderDisplayName":"Alex","unreadCount":4}"#)
        XCTAssertNil(FullDuplexVoiceClient.presentableScript(
            step: cleanup, lead: "Next, ", prepared: prepared))
        let threaded = step.replacingOccurrences(of: #""done":false"#,
            with: #""done":false,"thread":{"note":"Requeued for a decision."}"#)
        XCTAssertNotNil(FullDuplexVoiceClient.presentableScript(
            step: threaded, lead: "Next, ", prepared: prepared),
            "The opening and automatic advance must select recitation mode for a prepared thread")
    }

    func testTheOpeningRecitesThePreparedSummaryInsteadOfTheSnippet() throws {
        let opening = #"{"done":false,"item":{"account":"owner@example.test","id":"new","threadId":"thread","from":"Dropbox","subject":"Complete your Dropbox setup","identity":"Dropbox","date":"today","snippet":"Get up and running. Take your Dropbox to the next level."}}"#
        let key = try XCTUnwrap(LiveEmailPresentation.Key.step(opening))
        let prepared = LiveEmailPresentation(key: key,
            summary: "Dropbox is asking you to finish setting up your account.",
            from: "Dropbox <no-reply@dropbox.test>", to: "Owner <owner@example.test>",
            sentAt: "2026-09-15T15:00:00.000Z")
        let line = try XCTUnwrap(LiveSpokenStepContract.line(
            step: opening, lead: "First up, ", prepared: prepared))

        XCTAssertTrue(line.contains("Say exactly this, then stop:"))
        XCTAssertTrue(line.contains("First up, Dropbox is asking you"))
        XCTAssertTrue(line.contains("finish setting up your account"))
        XCTAssertFalse(line.contains("Complete your Dropbox setup"),
                       "A prepared presentation never announces the subject")
        XCTAssertFalse(line.contains("Sep 15, 2026"), "The sent date is never volunteered")
        XCTAssertFalse(line.contains("Take your Dropbox to the next level"),
                       "A prepared opening must not recite the sender's own wording")
        XCTAssertLessThanOrEqual(line.utf8.count, 450)

        // Nothing prepared, a summary for another message, and one too long to ride a single
        // append all fall back to the snippet line this replaced — never to a bodyless one.
        let otherStep = opening.replacingOccurrences(of: #""id":"new""#, with: #""id":"other""#)
        let other = LiveEmailPresentation(key: try XCTUnwrap(LiveEmailPresentation.Key.step(otherStep)),
            summary: "Please approve $50 by Friday.", from: prepared.from, to: prepared.to,
            sentAt: prepared.sentAt)
        let oversized = LiveEmailPresentation(key: key, summary: String(repeating: "Long. ", count: 80),
            from: prepared.from, to: prepared.to, sentAt: prepared.sentAt)
        for fallback in [nil, other, oversized] {
            let line = try XCTUnwrap(LiveSpokenStepContract.line(
                step: opening, lead: "First up, ", prepared: fallback))
            XCTAssertTrue(line.contains("First up, Dropbox. Get up and running."))
            XCTAssertLessThanOrEqual(line.utf8.count, 450)
        }
    }

    func testTheLaunchWarmedSummaryIsServedOnlyToItsOwnStepAndProfile() async throws {
        let key = try XCTUnwrap(LiveEmailPresentation.Key.step(step))
        let prepared = LiveEmailPresentation(key: key, summary: "Please approve $50 by Friday.",
            from: "Alex <alex@example.test>", to: "Owner <owner@example.test>", sentAt: "2026-09-15T15:00:00.000Z")
        let store = LiveEmailOpeningSummary(prepare: { _, _ in prepared })
        await store.warm([key], scope: nil)
        await store.awaitWarm()
        let now = Date()

        let served = await store.ready(for: step, profileId: nil, now: now)
        let otherProfile = await store.ready(for: step, profileId: "work", now: now)
        let expired = await store.ready(for: step, profileId: nil, now: now.addingTimeInterval(901))
        let otherMessage = await store.ready(
            for: step.replacingOccurrences(of: #""id":"new""#, with: #""id":"different""#),
            profileId: nil, now: now)
        await store.discard()
        let purged = await store.ready(for: step, profileId: nil, now: now)

        XCTAssertEqual(served?.summary, prepared.summary)
        XCTAssertNil(otherProfile)
        XCTAssertNil(expired)
        XCTAssertNil(otherMessage)
        XCTAssertNil(purged)
    }

    func testACachedSummarySurvivesContextDriftButNotAChangedChain() throws {
        let chain = step.replacingOccurrences(of: #""snippet":"preview""#,
            with: #""snippet":"preview","exchangeId":"reply-a","exchangeContext":[{"id":"old"}]"#)
        let key = try XCTUnwrap(LiveEmailPresentation.Key.step(chain))
        let prepared = LiveEmailPresentation(key: key, summary: "Please approve $50 by Friday.",
            from: "Alex <alex@example.test>", to: "Owner <owner@example.test>", sentAt: "2026-09-15T15:00:00.000Z")
        var cache = LiveEmailPreparationCache(profileId: "personal")
        cache.entries[key.identity] = (prepared, Date())
        let hydrated = chain.replacingOccurrences(of: #""exchangeContext":[{"id":"old"}]"#,
            with: #""exchangeContext":[{"id":"old"},{"id":"older"}]"#)
        let regrouped = chain.replacingOccurrences(of: #""snippet":"preview""#,
            with: #""snippet":"preview","messages":[{"id":"new"},{"id":"newer"}]"#)

        XCTAssertNotNil(cache.ready(for: hydrated, profileId: "personal"))
        XCTAssertNotNil(prepared.speakerLine(for: hydrated))
        XCTAssertNotNil(prepared.annotating(hydrated))
        XCTAssertNil(cache.ready(for: regrouped, profileId: "personal"))
    }

    func testTheCallAdoptsAWarmedSummaryInsteadOfPreparingItAgain() throws {
        let key = try XCTUnwrap(LiveEmailPresentation.Key.step(step))
        let prepared = LiveEmailPresentation(key: key, summary: "Please approve $50 by Friday.",
            from: "Alex <alex@example.test>", to: "Owner <owner@example.test>", sentAt: "2026-09-15T15:00:00.000Z")
        var cache = LiveEmailPreparationCache(profileId: "personal")
        cache.seed([prepared])

        XCTAssertNotNil(cache.ready(for: step, profileId: "personal"))
        XCTAssertFalse(cache.attempted.insert(key.identity).inserted)
        XCTAssertNil(cache.ready(for: step, profileId: "work"))
    }

    func testTheLaunchWarmHoldsEveryItemItWasGivenAndReleasesTheRest() async throws {
        let first = try XCTUnwrap(LiveEmailPresentation.Key.step(step))
        let second = try XCTUnwrap(LiveEmailPresentation.Key.step(
            step.replacingOccurrences(of: #""id":"new""#, with: #""id":"second""#)))
        let store = LiveEmailOpeningSummary(prepare: { key, _ in
            LiveEmailPresentation(key: key, summary: "Summary for \(key.messageId).",
                from: "Alex <alex@example.test>", to: "Owner <owner@example.test>",
                sentAt: "2026-09-15T15:00:00.000Z")
        })

        await store.warm([first, second], scope: nil)
        await store.awaitWarm()
        let both = await store.warmed(profileId: nil)
        await store.warm([second], scope: nil)
        await store.awaitWarm()
        let kept = await store.warmed(profileId: nil)

        XCTAssertEqual(Set(both.map(\.key.messageId)), ["new", "second"])
        XCTAssertEqual(kept.map(\.key.messageId), ["second"])
    }

    func testOversizedQuestionUsesTheSameGenericFallbackInSpeechAndContext() throws {
        let key = try XCTUnwrap(LiveEmailPresentation.Key.step(step))
        let prepared = LiveEmailPresentation(key: key,
            summary: String(repeating: "Summary ", count: 32),
            from: "Alex", to: "Owner", sentAt: "2026-09-15T15:00:00.000Z",
            suggestedQuestion: String(repeating: "Question ", count: 11) + "?")
        let line = try XCTUnwrap(prepared.speakerLine(for: step))
        XCTAssertTrue(line.contains(prepared.summary))
        XCTAssertTrue(line.contains("What would you like to do with it?"))
        XCTAssertLessThanOrEqual(line.utf8.count, 450)
        let annotated = try XCTUnwrap(prepared.annotating(step))
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(annotated.utf8)) as? [String: Any])
        let item = try XCTUnwrap(payload["item"] as? [String: Any])
        XCTAssertNil(item["suggestedQuestion"])
    }

    func testOpeningWarmRetainsOtherProfilesAndSeparatesUsers() async throws {
        let key = try XCTUnwrap(LiveEmailPresentation.Key.step(step))
        let store = LiveEmailOpeningSummary(prepare: { key, scope in
            LiveEmailPresentation(key: key, summary: scope?.profileId ?? "none",
                from: "Sender", to: "Owner", sentAt: "2026-09-21T15:00:00Z")
        })
        await store.warm([key], scope: .init(profileId: "personal", isDefault: true), userId: "alice")
        await store.warm([key], scope: .init(profileId: "work", isDefault: false), userId: "alice")
        await store.awaitWarm()
        let personal = await store.ready(for: step, profileId: "personal", userId: "alice")
        let work = await store.ready(for: step, profileId: "work", userId: "alice")
        let stranger = await store.ready(for: step, profileId: "work", userId: "bob")
        XCTAssertEqual(personal?.summary, "personal")
        XCTAssertEqual(work?.summary, "work")
        XCTAssertNil(stranger)
        await store.warm([], scope: .init(profileId: "personal", isDefault: true), userId: "alice")
        let removed = await store.warmed(profileId: "personal", userId: "alice")
        let retained = await store.warmed(profileId: "work", userId: "alice")
        XCTAssertTrue(removed.isEmpty)
        XCTAssertEqual(retained.count, 1)
        await store.discard()
        let purged = await store.warmed(profileId: "work", userId: "alice")
        XCTAssertTrue(purged.isEmpty)
    }

    func testSpeechNeverSplitsOrTruncatesAnOversizedSummary() throws {
        let key = try XCTUnwrap(LiveEmailPresentation.Key.step(step))
        let prepared = LiveEmailPresentation(key: key, summary: String(repeating: "Long email. ", count: 100),
            from: "Alex <alex@example.test>", to: "Owner <owner@example.test>", sentAt: "2026-09-15T15:00:00.000Z")
        XCTAssertNil(prepared.speakerLine(for: step))
    }
    static func cleanupStep(category: GmailMailCategory = .promotions,
                            action: EmailCleanupDecision.Action = .archive,
                            atLeast: Bool = false, from: String = "Kollar Clothing <offers@kollar.test>") throws -> [String: Any] {
        let input = EmailCleanupInput(account: "owner@example.test", id: "current", from: from)
        let cleanup = try XCTUnwrap(EmailCleanupPolicy.cleanupPayload(item: input,
            decision: EmailCleanupDecision(category: category, action: action, senderInboxCount: 13, atLeast: atLeast)))
        return ["done": false, "item": ["account": input.account, "id": input.id,
            "threadId": "thread", "from": from, "identity": "Kollar Clothing"], "cleanup": cleanup]
    }

    static func encode(_ payload: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
    }

    func testCleanupOffersSpeakExactCountSenderAndActionWithoutSummaryCache() throws {
        for (category, action) in [(GmailMailCategory.promotions, EmailCleanupDecision.Action.archive),
                                   (.promotions, .unsubscribe), (.purchases, .archive)] {
            for atLeast in [false, true] {
                let step = try Self.encode(Self.cleanupStep(category: category, action: action, atLeast: atLeast))
                let line = try XCTUnwrap(LiveEmailPresentation.cleanupSpeakerLine(for: step))
                XCTAssertTrue(line.contains("\(atLeast ? "at least " : "")13"))
                XCTAssertTrue(line.contains("from Kollar Clothing"))
                XCTAssertEqual(line.contains("I can unsubscribe"), action == .unsubscribe)
                XCTAssertTrue(line.contains(action == .unsubscribe ? "Should I go ahead and do that?" : "Shall I do that?"))
                XCTAssertTrue(line.contains(EmailCleanupPolicy.alternativeOfferSentence))
                XCTAssertTrue(line.contains("Wait for approval"))
                XCTAssertLessThanOrEqual(line.utf8.count, 450)
                XCTAssertEqual(LiveSpokenStepContract.line(step: step, lead: "First up, "), line)
                XCTAssertEqual(LiveSpokenStepContract.line(step: step, lead: "Next, "), line)
                XCTAssertNil(LiveEmailPreparationCache().ready(for: step, profileId: nil),
                             "The offer must not depend on an ordinary email summary")
            }
        }
    }

    func testCleanupSpeechRejectsChangedIdentityScopeAndExecutionContract() throws {
        let base = try Self.cleanupStep()
        for (key, value) in [("account", "other@example.test"), ("messageId", "other"),
                             ("sender", "other@kollar.test"), ("senderDisplayName", "Someone else"),
                             ("query", "in:inbox"), ("state", "accepted"), ("action", "trash")] {
            var payload = base
            var cleanup = try XCTUnwrap(payload["cleanup"] as? [String: Any])
            cleanup[key] = value
            payload["cleanup"] = cleanup
            XCTAssertNil(LiveEmailPresentation.cleanupSpeakerLine(for: try Self.encode(payload)), key)
        }
        var payload = base
        var cleanup = try XCTUnwrap(payload["cleanup"] as? [String: Any])
        cleanup["requiresApproval"] = false
        payload["cleanup"] = cleanup
        XCTAssertNil(LiveEmailPresentation.cleanupSpeakerLine(for: try Self.encode(payload)))
        cleanup = try XCTUnwrap(base["cleanup"] as? [String: Any])
        var dispatch = try XCTUnwrap(cleanup["dispatch"] as? [String: Any])
        dispatch["account"] = "other@example.test"
        cleanup["dispatch"] = dispatch
        payload["cleanup"] = cleanup
        XCTAssertNil(LiveEmailPresentation.cleanupSpeakerLine(for: try Self.encode(payload)))
    }

    func testCleanupSpeechKeepsSpecialStepsAndOversizedNamesOnBackend() throws {
        let base = try Self.cleanupStep()
        for field in ["interstitial", "onboarding", "coaching", "dispatchOutcome", "presentedForOutcome", "thread"] {
            var payload = base
            payload[field] = [:] as [String: String]
            XCTAssertNil(LiveEmailPresentation.cleanupSpeakerLine(for: try Self.encode(payload)), field)
        }
        var done = base
        done["done"] = true
        XCTAssertNil(LiveEmailPresentation.cleanupSpeakerLine(for: try Self.encode(done)))
        let oversized = try Self.encode(Self.cleanupStep(action: .unsubscribe,
            from: String(repeating: "🌍", count: 80) + " <offers@kollar.test>"))
        XCTAssertNil(LiveEmailPresentation.cleanupSpeakerLine(for: oversized),
                     "Never truncate the sender, action or approval question to fit")
    }

    func testPreparedQuestionIsSpokenAndCarriedToTheBackendForTheSameEmail() throws {
        let key = try XCTUnwrap(LiveEmailPresentation.Key.step(step))
        let prepared = LiveEmailPresentation(key: key, summary: "Alex wants a meeting next week.",
            from: "Alex", to: "Owner", sentAt: "2026-09-21T15:00:00Z",
            suggestedQuestion: "How do you want to respond?")
        for line in [prepared.speakerLine(for: step),
                     LiveSpokenStepContract.line(step: step, lead: "First up, ", prepared: prepared)] {
            let speech = try XCTUnwrap(line)
            XCTAssertTrue(speech.contains(try XCTUnwrap(prepared.suggestedQuestion)))
            XCTAssertFalse(speech.contains("What would you like to do with it?"))
            XCTAssertLessThanOrEqual(speech.utf8.count, 450)
        }
        let annotated = try XCTUnwrap(prepared.annotating(step))
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(annotated.utf8)) as? [String: Any])
        let item = try XCTUnwrap(payload["item"] as? [String: Any])
        XCTAssertEqual(item["suggestedQuestion"] as? String, prepared.suggestedQuestion)
        let otherAccount = step.replacingOccurrences(of: "owner@example.test", with: "other@example.test")
        XCTAssertNil(prepared.annotating(otherAccount))
        XCTAssertNil(prepared.speakerLine(for: otherAccount))
    }

    func testOlderBrokerSummaryStillDecodesWithoutAQuestion() throws {
        let key = try XCTUnwrap(LiveEmailPresentation.Key.step(step))
        let legacy = LiveEmailPresentation(key: key, summary: "Alex needs approval.",
            from: "Alex", to: "Owner", sentAt: "2026-09-21T15:00:00Z")
        let decoded = try JSONDecoder().decode(LiveEmailPresentation.self, from: JSONEncoder().encode(legacy))
        XCTAssertNil(decoded.suggestedQuestion)
        XCTAssertTrue(decoded.speakerLine(for: step)?.contains("What would you like to do with it?") == true)
    }

    func testUnheardGuardListensForTheSpokenIdentity() {
        let step = #"{"done":false,"item":{"from":"\"Lee, Sam\" <sam@example.test>","identity":"Sam Lee"}}"#
        let words = FullDuplexVoiceClient.senderWords(step)
        XCTAssertEqual(words, ["sam", "lee"])
        XCTAssertFalse(FullDuplexVoiceClient.speaksSender("with the signed copy attached. Sure, archiving.", sender: words))
        XCTAssertTrue(FullDuplexVoiceClient.speaksSender("Next, Sam wants to move the call", sender: words))
        XCTAssertTrue(FullDuplexVoiceClient.senderWords(
            #"{"done":false,"item":{"from":"a@example.test","identity":"a@example.test"}}"#).isEmpty)
    }

}
