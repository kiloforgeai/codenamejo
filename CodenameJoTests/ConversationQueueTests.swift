import XCTest
import GRDB
@testable import CodenameJo

final class ConversationQueueTests: XCTestCase {
    private func message(
        _ id: String,
        from: String,
        minutesAgo: Int,
        unread: Bool = true
    ) -> LocalTriageQueue.Item.Message {
        LocalTriageQueue.Item.Message(
            id: id,
            from: from,
            subject: "Re: Project update: August",
            date: "2026-09-02T14:00:00Z",
            snippet: "Snippet \(id)",
            internalDate: 1_788_000_000_000 - Int64(minutesAgo) * 60_000,
            unread: unread, exchangeID: "fixture-exchange")
    }

    private func item(
        _ threadId: String,
        _ messages: [LocalTriageQueue.Item.Message],
        account: String = "you@kiloforge.test"
    ) -> LocalTriageQueue.Item {
        let newest = messages.max { $0.internalDate < $1.internalDate }!
        return LocalTriageQueue.Item(
            account: account,
            id: newest.id,
            threadId: threadId,
            from: newest.from,
            subject: newest.subject,
            date: newest.date,
            snippet: newest.snippet,
            internalDate: newest.internalDate,
            messages: messages)
    }

    func testPresentationRejectsActionsAndChangedMembersDuringHydration() {
        let captured = item("thread", [message("old", from: "Sam", minutesAgo: 2),
                                       message("new", from: "Priya", minutesAgo: 1)])
        XCTAssertTrue(LocalTriageQueue.presentationMatches(captured, current: captured))
        var changed = captured
        changed.acted = "archive_message"
        XCTAssertFalse(LocalTriageQueue.presentationMatches(captured, current: changed))
        changed = captured
        changed.markedRead = true
        XCTAssertFalse(LocalTriageQueue.presentationMatches(captured, current: changed))
        changed = captured.keeping([captured.conversation[0]])!
        XCTAssertFalse(LocalTriageQueue.presentationMatches(captured, current: changed))
        changed = captured
        changed.hasDraft = true
        XCTAssertTrue(LocalTriageQueue.presentationMatches(captured, current: changed))
    }

    func testTheSpokenIdentityNeverCarriesTheSubject() {
        var item = LocalTriageQueue.Item(
            account: "owner@example.test", id: "new", threadId: "thread",
            from: "Joe Garcia <joe@example.test>", subject: "Recommendation for an AI engineer",
            date: "2026-09-14T10:00:00Z", snippet: "Summary", internalDate: 2)
        item.displayGroupID = "read-thread"
        item.summaryMessages = [.init(id: "newest", from: "Joe Garcia <joe@example.test>",
            subject: "", date: "2026-09-14T11:00:00Z", snippet: "Newer", internalDate: 3)]
        XCTAssertEqual(LocalTriageQueue.spokenIdentity(item), "Joe Garcia")

        var blank = item
        blank.subject = ""
        XCTAssertEqual(LocalTriageQueue.spokenIdentity(blank), "Joe Garcia")

        var sent = blank
        sent.from = "Owner <owner@example.test>"
        sent.recipient = "Dana Whitfield <dana@example.test>"
        sent.summaryMessages = nil
        XCTAssertEqual(LocalTriageQueue.spokenIdentity(sent), "Your message to Dana Whitfield")

        var otherMailbox = sent
        otherMailbox.from = "Owner <owner.personal@example.test>"
        XCTAssertEqual(LocalTriageQueue.spokenIdentity(otherMailbox), "Owner")
        XCTAssertEqual(LocalTriageQueue.spokenIdentity(otherMailbox, owned: ["owner.personal@example.test"]),
                       "Your message to Dana Whitfield", "Sent from another connected mailbox")
    }

    func testSpokenIdentityNamesTheLatestSenderWithoutAnAddress() {
        let current = LocalTriageQueue.Item(
            account: "owner@example.test", id: "new", threadId: "thread",
            from: "Latest Lee <latest@example.test>", subject: "Current subject",
            date: "2026-09-14T10:00:00Z", snippet: "Current summary", internalDate: 2)
        XCTAssertEqual(LocalTriageQueue.spokenIdentity(current), "Latest Lee")

        var inboundWithToHeader = current
        inboundWithToHeader.recipient = "Owner <owner@example.test>"
        XCTAssertEqual(LocalTriageQueue.spokenIdentity(inboundWithToHeader), "Latest Lee")
    }

    func testSpokenIdentitySaysTheAddressWhenTheHeaderCarriesNoName() {
        let bare = LocalTriageQueue.Item(
            account: "owner@example.test", id: "new", threadId: "thread",
            from: "latest@example.test", subject: "Current subject",
            date: "2026-09-14T10:00:00Z", snippet: "Current summary", internalDate: 2)
        XCTAssertEqual(LocalTriageQueue.spokenIdentity(bare), "latest@example.test")

        var angled = bare
        angled.from = "<Latest@Example.test>"
        XCTAssertEqual(LocalTriageQueue.spokenIdentity(angled), "latest@example.test")

        var unspeakable = bare
        unspeakable.from = "\"a@b\" <no-at-sign>"
        XCTAssertEqual(LocalTriageQueue.spokenIdentity(unspeakable), "the sender")
    }

    func testSpokenIdentityUsesTheLatestApplicableContextMember() {
        var selected = item(
            "thread", [message("selected", from: "Earlier Erin", minutesAgo: 2)])
        selected.exchangeContext = [
            LocalTriageQueue.Item.Message(
                id: "reply", from: "Latest Lee", subject: "Latest subject",
                date: "2026-09-14T10:01:00Z", snippet: "Latest summary",
                internalDate: selected.internalDate + 60_000, unread: false,
                exchangeID: "fixture-exchange"),
        ]
        XCTAssertEqual(LocalTriageQueue.spokenIdentity(selected), "Latest Lee")
    }

    func testSpokenIdentityUsesRecipientForSentMail() {
        var sent = item(
            "thread", [message("sent", from: "Owner <you@kiloforge.test>", minutesAgo: 1)])
        sent.recipient = "Dana <dana@example.test>"
        XCTAssertEqual(LocalTriageQueue.spokenIdentity(sent), "Your message to Dana")

        sent.recipient = "Dana <dana@example.test>, Bob <bob@example.test>"
        XCTAssertEqual(LocalTriageQueue.spokenIdentity(sent), "Your message to Dana and Bob")

        sent.recipient = "dana@example.test, bob@example.test"
        XCTAssertEqual(LocalTriageQueue.spokenIdentity(sent), "Your message to the recipients")

        sent.recipient = "\"dana@example.test\" <dana@example.test>"
        XCTAssertEqual(LocalTriageQueue.spokenIdentity(sent), "Your message to dana@example.test")
    }

    func testMalformedAndContradictoryKnownAncestryStaysSingleton() {
        XCTAssertEqual(LocalTriageQueue.exchangeID(messageID: "a", rfcID: "garbage <a@test>",
            inReplyTo: "<root@test>", references: "<root@test>"), "message:a")
        var ancestor = message("known", from: "Root", minutesAgo: 3)
        ancestor.rfcMessageID = "<branch@test>"
        ancestor.inReplyTo = "<other@test>"
        ancestor.references = "<other@test>"
        XCTAssertEqual(LocalTriageQueue.exchangeID(messageID: "a", rfcID: "<a@test>",
            inReplyTo: "<branch@test>", references: "<root@test> <branch@test>", context: [ancestor]), "message:a")
    }

    func testFullThreadContextDoesNotExpandActionMembership() throws {
        let json = #"{"id":"thread","messages":[{"id":"root","threadId":"thread","labelIds":[],"internalDate":"10","payload":{"headers":[{"name":"Message-ID","value":"<root@test>"}]}},{"id":"reply","threadId":"thread","labelIds":["INBOX"],"internalDate":"20","payload":{"headers":[{"name":"Message-ID","value":"<reply@test>"},{"name":"In-Reply-To","value":"<root@test>"},{"name":"References","value":"<root@test>"}]}}]}"#
        let thread = try JSONDecoder().decode(GmailAPI.ThreadMetadata.self, from: Data(json.utf8))
        let selected = LocalTriageQueue.liveItem(from: MailStore.Ingest(detail: thread.messages![1], account: "you@test"))
        let enriched = LocalTriageQueue.withThreadContext(selected, thread: thread, verified: true)
        XCTAssertEqual(enriched.ids, ["reply"])
        XCTAssertEqual(enriched.summaryMessages?.map(\.id), ["root", "reply"])
        XCTAssertEqual(enriched.conversation.count, 1)
        let grouped = LocalTriageQueue.groupByConversation([enriched], grouping: true)
        XCTAssertEqual(grouped.first?.displayGroupID, "read-thread")
        XCTAssertEqual(grouped.first?.summaryMessages?.count, 2)
    }

    func testFetchedAncestryRepairsCachedMixedSenderChainBeforeGrouping() throws {
        let thread = try hydrationThread()
        let selected = thread.messages!.filter { $0.id != "root" }.map { detail in
            var selected = LocalTriageQueue.liveItem(from: MailStore.Ingest(detail: detail, account: "you@test"))
            selected.messages = selected.conversation.map { member in
                var stale = member
                stale.rfcMessageID = nil
                stale.inReplyTo = nil
                stale.references = nil
                stale.ancestryCached = false
                stale.exchangeID = "message:" + member.id
                return stale
            }
            return selected
        }
        XCTAssertEqual(LocalTriageQueue.groupByConversation(selected, grouping: true).count, 3)
        let hydrated = selected.map { LocalTriageQueue.withThreadContext($0, thread: thread, verified: false) }
        let grouped = LocalTriageQueue.groupByConversation(hydrated, grouping: true)
        XCTAssertEqual(grouped.count, 1)
        XCTAssertEqual(grouped.first?.ids, ["auditor", "owner", "agent"])
        XCTAssertEqual(grouped.first?.id, "agent")
        XCTAssertEqual(Set(grouped.first?.exchangeContext?.map(\.id) ?? []), ["root", "auditor", "owner", "agent"])
        XCTAssertTrue(hydrated.allSatisfy { $0.conversation[0].ancestryCached == true })
        XCTAssertEqual(LiveEmailPresentation.Key.item(try XCTUnwrap(grouped.first))?.messageIDs,
                       ["agent", "auditor", "owner", "root"])
        XCTAssertEqual(LocalTriageQueue.messageCount(try XCTUnwrap(grouped.first), scope: .unread, grouping: true), 3)
    }

    func testFetchedAncestryReplacesStaleHeadersButPreservesSelectionState() throws {
        let thread = try hydrationThread()
        var selected = item("audit", [message("owner", from: "Owner", minutesAgo: 1, unread: false)])
        selected.messages?[0].rfcMessageID = "<outdated@test>"
        selected.messages?[0].inReplyTo = "<wrong@test>"
        selected.messages?[0].references = "<wrong@test>"
        selected.messages?[0].queueWeight = 2
        selected.messages?[0].topicId = "saved-topic"
        selected.displayGroupID = "saved-continuation"
        selected.unresolvedContinuation = true
        let hydrated = LocalTriageQueue.withThreadContext(selected, thread: thread, verified: false)
        XCTAssertEqual(hydrated.ids, ["owner"])
        XCTAssertEqual(hydrated.conversation[0].rfcMessageID, "<owner@test>")
        XCTAssertEqual(hydrated.conversation[0].references, "<root@test> <auditor@test>")
        XCTAssertFalse(hydrated.conversation[0].unread)
        XCTAssertEqual(hydrated.conversation[0].queueWeight, 2)
        XCTAssertEqual(hydrated.conversation[0].topicId, "saved-topic")
        XCTAssertEqual(hydrated.displayGroupID, "saved-continuation")
        XCTAssertEqual(hydrated.unresolvedContinuation, true)
        XCTAssertEqual(LocalTriageQueue.groupByConversation([hydrated], grouping: true).first?.displayGroupID,
                       "saved-continuation")
    }

    func testFetchedAncestryKeepsOtherBranchesAndUnknownMembersSeparate() throws {
        let thread = try hydrationThread(includeBranch: true)
        let selected = ["auditor", "agent", "other", "absent"].map { id in
            LocalTriageQueue.withThreadContext(item("audit", [message(id, from: "Sender", minutesAgo: 1)]),
                thread: thread, verified: false)
        }
        let grouped = LocalTriageQueue.groupByConversation(selected, grouping: true)
        XCTAssertEqual(grouped.count, 3)
        XCTAssertTrue(grouped.contains { Set($0.ids) == ["auditor", "agent"] })
        XCTAssertTrue(grouped.contains { $0.ids == ["other"] })
        XCTAssertTrue(grouped.contains { $0.ids == ["absent"] })
        let foreign = item("unrelated", [message("agent", from: "Sender", minutesAgo: 1)])
        XCTAssertEqual(LocalTriageQueue.withThreadContext(foreign, thread: thread, verified: false), foreign)
    }

    func testFetchedConflictingAncestryDoesNotRetainAnOlderGroup() throws {
        let thread = try hydrationThread(conflictingParent: true)
        var selected = item("audit", [message("agent", from: "Agent", minutesAgo: 1)])
        selected.messages?[0].rfcMessageID = "<agent@test>"
        selected.messages?[0].inReplyTo = "<owner@test>"
        selected.messages?[0].references = "<root@test> <auditor@test> <owner@test>"
        let hydrated = LocalTriageQueue.withThreadContext(selected, thread: thread, verified: false)
        XCTAssertEqual(hydrated.conversation[0].exchangeID, "message:agent")
        XCTAssertEqual(hydrated.conversation[0].inReplyTo, "<conflict@test>")
    }

    private func hydrationThread(includeBranch: Bool = false, conflictingParent: Bool = false) throws -> GmailAPI.ThreadMetadata {
        var members: [(String, String, String, String)] = [
            ("root", "Auditor", "", ""),
            ("auditor", "Auditor", "root", "<root@test>"),
            ("owner", "Owner", "auditor", "<root@test> <auditor@test>"),
            ("agent", "Agent", conflictingParent ? "conflict" : "owner", "<root@test> <auditor@test> <owner@test>")
        ]
        if includeBranch { members.append(("other", "Other", "root", "<root@test>")) }
        let messages: [[String: Any]] = members.enumerated().map { index, member in
            ["id": member.0, "threadId": "audit", "internalDate": String(index + 1),
             "labelIds": index == 0 ? [] : ["INBOX", "UNREAD"],
             "payload": ["headers": [
                ["name": "From", "value": member.1],
                ["name": "Message-ID", "value": "<\(member.0)@test>"],
                ["name": "In-Reply-To", "value": member.2.isEmpty ? "" : "<\(member.2)@test>"],
                ["name": "References", "value": member.3]
             ]]]
        }
        return try JSONDecoder().decode(GmailAPI.ThreadMetadata.self,
            from: JSONSerialization.data(withJSONObject: ["id": "audit", "messages": messages]))
    }

    func testReplyAncestryKeepsSecretaryAndOwnRepliesInTheExchange() {
        let branch = LocalTriageQueue.exchangeID(messageID: "john", rfcID: "<john@example.test>",
            inReplyTo: "<root@example.test>", references: "<root@example.test>")
        let descendant = LocalTriageQueue.exchangeID(messageID: "secretary", rfcID: "<sec@example.test>",
            inReplyTo: "<own@example.test>", references: "<root@example.test> <john@example.test>\r\n <own@example.test>")
        let other = LocalTriageQueue.exchangeID(messageID: "amy", rfcID: "<amy@example.test>",
            inReplyTo: "<root@example.test>", references: "<root@example.test>")
        XCTAssertEqual(branch, descendant)
        XCTAssertNotEqual(branch, other)
    }

    func testRootJoinsItsOnlyReplyChainWithoutMergingIndependentBranches() {
        var root = message("root", from: "Me", minutesAgo: 3)
        root.rfcMessageID = "<root@test>"
        var reply = message("reply", from: "John", minutesAgo: 2)
        reply.rfcMessageID = "<reply@test>"
        reply.inReplyTo = "<root@test>"
        reply.references = "<root@test>"
        var followup = message("followup", from: "Secretary", minutesAgo: 1)
        followup.rfcMessageID = "<followup@test>"
        followup.inReplyTo = "<reply@test>"
        followup.references = "<root@test> <reply@test>"
        let source = [root, reply, followup].map { item("thread", [$0]) }
        let grouped = LocalTriageQueue.groupByConversation(source, grouping: true)
        XCTAssertEqual(grouped.count, 1)
        XCTAssertEqual(grouped.first?.ids, ["root", "reply", "followup"])
        XCTAssertEqual(grouped.first?.id, "followup")
        XCTAssertEqual(LocalTriageQueue.groupByConversation(source, grouping: false).count, 3)

        followup.inReplyTo = "<root@test>"
        followup.references = "<root@test>"
        XCTAssertEqual(LocalTriageQueue.groupByConversation(
            [root, reply, followup].map { item("thread", [$0]) }, grouping: true).count, 3)
        XCTAssertEqual(LocalTriageQueue.groupByConversation([
            item("thread", [root]), item("other-thread", [reply]),
            item("thread", [reply], account: "other@example.test")], grouping: true).count, 3)
    }

    func testFreshCachedExchangeIDsUseAvailableAncestryButSavedStopsStayStable() {
        var root = message("root", from: "Me", minutesAgo: 2)
        root.rfcMessageID = "<root@test>"
        root.exchangeID = "message:root"
        var reply = message("reply", from: "John", minutesAgo: 1)
        reply.rfcMessageID = "<reply@test>"
        reply.inReplyTo = "<root@test>"
        reply.references = "<root@test>"
        reply.exchangeID = LocalTriageQueue.exchangeID(messageID: reply.id, rfcID: reply.rfcMessageID,
            inReplyTo: reply.inReplyTo, references: reply.references)
        let source = [root, reply].map { item("thread", [$0]) }
        XCTAssertEqual(LocalTriageQueue.groupByConversation(source, grouping: true).first?.ids, ["root", "reply"])
        let saved = source.map { original in
            var saved = original
            saved.displayGroupID = original.conversation[0].exchangeID
            return saved
        }
        XCTAssertEqual(LocalTriageQueue.groupByConversation(saved, grouping: true).count, 2)
        reply.inReplyTo = "<wrong@test>"
        XCTAssertEqual(LocalTriageQueue.groupByConversation(
            [root, reply].map { item("thread", [$0]) }, grouping: true).count, 2)
    }

    func testSameThreadNotificationsWithoutAncestryStaySeparate() {
        var first = message("first", from: "Notifications", minutesAgo: 2)
        first.rfcMessageID = "<first@test>"
        var second = message("second", from: "Notifications", minutesAgo: 1)
        second.rfcMessageID = "<second@test>"
        XCTAssertEqual(LocalTriageQueue.groupByConversation(
            [first, second].map { item("thread", [$0]) }, grouping: true).count, 2)
    }

    func testRootUsesReadReplyContextWithoutExpandingSelection() {
        var root = message("root", from: "Me", minutesAgo: 2)
        root.rfcMessageID = "<root@test>"
        var reply = message("reply", from: "John", minutesAgo: 1, unread: false)
        reply.rfcMessageID = "<reply@test>"
        reply.inReplyTo = "<root@test>"
        reply.references = "<root@test>"
        reply.exchangeID = LocalTriageQueue.exchangeID(messageID: reply.id, rfcID: reply.rfcMessageID,
            inReplyTo: reply.inReplyTo, references: reply.references)
        var selected = item("thread", [root])
        selected.exchangeContext = [root, reply]
        let grouped = LocalTriageQueue.groupByConversation([selected], grouping: true)
        XCTAssertEqual(grouped.first?.ids, ["root"])
        XCTAssertEqual(grouped.first?.exchangeContext?.map(\.id), ["reply"])
        XCTAssertEqual(grouped.first?.displayGroupID, reply.exchangeID)
    }

    func testUnreadReplySelectedElsewhereStillInformsTheSummary() throws {
        var root = message("root", from: "Marty", minutesAgo: 2)
        root.rfcMessageID = "<root@test>"
        var reply = message("reply", from: "Gaurav", minutesAgo: 1)
        reply.rfcMessageID = "<reply@test>"
        reply.inReplyTo = "<root@test>"
        reply.references = "<root@test>"
        reply.exchangeID = LocalTriageQueue.exchangeID(messageID: reply.id, rfcID: reply.rfcMessageID,
            inReplyTo: reply.inReplyTo, references: reply.references)
        var selected = item("thread", [root])
        selected.exchangeContext = [root, reply]
        let grouped = try XCTUnwrap(LocalTriageQueue.groupByConversation([selected], grouping: true).first)
        XCTAssertEqual(grouped.ids, ["root"])
        XCTAssertEqual(grouped.exchangeContext?.map(\.id), ["reply"])
        XCTAssertEqual(LiveEmailPresentation.Key.item(grouped)?.messageIDs, ["reply", "root"])
        XCTAssertEqual(LocalTriageQueue.messageCount(grouped, scope: .unread, grouping: true), 1)

        var replyStop = item("thread", [reply])
        replyStop.exchangeContext = [root, reply]
        let merged = LocalTriageQueue.groupByConversation([selected, replyStop], grouping: true)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.ids, ["root", "reply"])
        XCTAssertEqual(LiveEmailPresentation.Key.item(try XCTUnwrap(merged.first))?.messageIDs, ["reply", "root"])
        XCTAssertEqual(LocalTriageQueue.messageCount(try XCTUnwrap(merged.first), scope: .unread, grouping: true), 2)
    }

    func testReadParentStaysContextWhenAPartialActionSplitsTheStop() throws {
        var parent = message("parent", from: "Seb", minutesAgo: 2, unread: false)
        parent.rfcMessageID = "<parent@test>"
        var reply = message("reply", from: "Seb", minutesAgo: 1)
        reply.rfcMessageID = "<reply@test>"
        reply.inReplyTo = "<parent@test>"
        reply.references = "<parent@test>"
        let exchange = LocalTriageQueue.exchangeID(messageID: reply.id, rfcID: reply.rfcMessageID,
            inReplyTo: reply.inReplyTo, references: reply.references)
        parent.exchangeID = exchange
        reply.exchangeID = exchange
        let stops = [parent, reply].map { member -> LocalTriageQueue.Item in
            var stop = item("thread", [member])
            stop.exchangeContext = [parent, reply]
            return stop
        }
        let grouped = try XCTUnwrap(LocalTriageQueue.groupByConversation(stops, grouping: true).first)
        XCTAssertEqual(grouped.ids, ["parent", "reply"])
        let continuation = try XCTUnwrap(grouped.keeping(grouped.conversation.filter { $0.id == "reply" }))
        XCTAssertEqual(LiveEmailPresentation.Key.item(continuation)?.messageIDs, ["parent", "reply"])
    }

    func testAmbiguousAncestryDoesNotGuessAnExchange() {
        for (parent, refs) in [("<wrong@example.test>", "<root@example.test>"),
                               ("<root@example.test>", "<root@example.test> <root@example.test>"),
                               ("<a@example.test> <b@example.test>", "<root@example.test>"),
                               ("", "<current@example.test>")] {
            XCTAssertEqual(LocalTriageQueue.exchangeID(messageID: "current", rfcID: "<current@example.test>",
                inReplyTo: parent, references: refs), "message:current")
        }
        XCTAssertEqual(LocalTriageQueue.exchangeID(messageID: "missing", rfcID: nil,
            inReplyTo: nil, references: nil), "message:missing")
    }

    func testUnreadExchangesRemainDistinctButReadThreadGetsOneSummary() {
        var john = message("john", from: "John", minutesAgo: 3)
        var own = message("own", from: "Me", minutesAgo: 2, unread: false)
        var amy = message("amy", from: "Amy", minutesAgo: 1)
        john.exchangeID = "john-branch"
        own.exchangeID = "john-branch"
        amy.exchangeID = "amy-branch"
        let distinct = LocalTriageQueue.groupByConversation([item("thread", [john, own, amy])], grouping: true)
        XCTAssertEqual(distinct.count, 2)
        XCTAssertEqual(Set(distinct.flatMap(\.ids)), ["john", "own", "amy"])
        XCTAssertEqual(distinct.last?.ids, ["john", "own"])
        john.unread = false
        amy.unread = false
        let unverified = item("thread", [john, own, amy])
        XCTAssertEqual(LocalTriageQueue.groupByConversation([unverified], grouping: true).count, 2)
        var verified = unverified
        verified.threadReadVerified = true
        let read = LocalTriageQueue.groupByConversation([verified], grouping: true)
        XCTAssertEqual(read.count, 1)
        XCTAssertEqual(read.first?.displayGroupID, "read-thread")
        XCTAssertEqual(read.first?.ids.count, 3)
    }

    func testExchangePagingNeverDropsOtherBranchesAndKeepsCurrentStable() {
        // One sender per branch: a second sender's unread mail is its own stop, which is
        // what `testEachUnreadSenderInAThreadIsItsOwnStop` pins. This is about paging.
        var john = message("john", from: "John", minutesAgo: 3)
        var reply = message("reply", from: "John", minutesAgo: 2)
        var amy = message("amy", from: "Amy", minutesAgo: 1)
        john.exchangeID = "john-branch"
        reply.exchangeID = "john-branch"
        amy.exchangeID = "amy-branch"
        let buffer = LocalTriageQueue.groupByConversation([item("thread", [john])], grouping: true)
        let page = [item("thread", [reply, amy])]
        let ahead = LocalTriageQueue.appendingPage(page, to: buffer, position: 0, grouping: true)
        XCTAssertEqual(ahead.count, 2)
        XCTAssertEqual(Set(ahead.flatMap(\.ids)), ["john", "reply", "amy"])
        let current = LocalTriageQueue.appendingPage(page, to: buffer, position: 1, grouping: true)
        XCTAssertEqual(current.first?.ids, ["john"])
        XCTAssertEqual(Set(current.flatMap(\.ids)), ["john", "reply", "amy"])
    }

    func testReadSummarySuppressesOnlyOldReadMembersInItsMailbox() {
        var read = message("read", from: "John", minutesAgo: 3, unread: false)
        var fresh = message("fresh", from: "Secretary", minutesAgo: 1)
        read.exchangeID = "john-branch"
        fresh.exchangeID = "john-branch"
        var old = item("thread", [read])
        let unverified = old
        old.displayGroupID = "read-thread"
        old.threadReadVerified = true
        var incoming = item("thread", [read, fresh])
        incoming.displayGroupID = "read-thread"
        incoming.threadReadVerified = true
        let other = item("thread", [read], account: "other@test")
        var pending = old
        pending.unresolvedContinuation = true
        let filtered = LocalTriageQueue.excludingSummarizedReadThreads([old, incoming, other, pending, unverified],
            keys: ["thread:you@kiloforge.test|thread"])
        XCTAssertEqual(filtered.count, 4)
        XCTAssertEqual(filtered.last?.ids, ["read"])
        XCTAssertEqual(filtered[0].ids, ["fresh"])
        XCTAssertEqual(filtered[1].account, "other@test")
        XCTAssertEqual(filtered[2].ids, ["read"])
    }

    func testReplyAncestrySurvivesCacheAndSnapshotRoundTrip() throws {
        let db = try DatabaseQueue()
        try db.write { db in
            try MailStore.createUserScopedSchema(db)
            try MailStore.addReplyAncestry(db)
            let row = MailStore.Message(user_id: "test-user", id: "reply", account: "you@test", threadId: "thread", sender: "Secretary",
                recipient: nil, subject: "Update", snippet: nil, internalDate: 1, cachedAt: Date(),
                rfcMessageID: "<reply@test>", inReplyTo: "<john@test>",
                referenceHeaders: "<root@test> <john@test>", ancestryCached: true)
            try row.insert(db)
            let saved = try XCTUnwrap(MailStore.Message.fetchOne(
                db, key: ["user_id": "test-user", "account": "you@test", "id": "reply"]))
            XCTAssertEqual(saved.referenceHeaders, row.referenceHeaders)
            XCTAssertEqual(saved.ancestryCached, true)
        }
        var member = message("reply", from: "Secretary", minutesAgo: 1)
        member.exchangeID = "branch-key"
        let group = try XCTUnwrap(LocalTriageQueue.groupByConversation([item("thread", [member])], grouping: true).first)
        let restored = try JSONDecoder().decode(LocalTriageQueue.Item.self, from: JSONEncoder().encode(group))
        XCTAssertEqual(restored.displayGroupID, "branch-key")
        XCTAssertEqual(restored.conversation.first?.exchangeID, "branch-key")
    }

    func testReadRepresentativesCountAsSelectedMessagesOnAll() {
        let read = item("thread", [message("read", from: "Sam", minutesAgo: 1, unread: false)])
        XCTAssertEqual(LocalTriageQueue.messageCount(read, scope: .unread, grouping: true), 0)
        XCTAssertEqual(LocalTriageQueue.messageCount(read, scope: .all, grouping: true), 1)
    }

    func testSectionGroupingPreservesPriorityAndMemberChronology() {
        let priority = item("priority", [message("old", from: "Sam", minutesAgo: 10)])
        let recent = item("recent", [message("recent", from: "Priya", minutesAgo: 1)])
        // Same sender as the priority member: two senders would be two stops.
        let reply = item("priority", [message("reply", from: "Sam", minutesAgo: 5)])
        let result = LocalTriageQueue.groupByConversation([priority, recent, reply],
            grouping: true, preserveOrder: true)
        XCTAssertEqual(result.map(\.threadId), ["priority", "recent"])
        XCTAssertEqual(result.first?.ids, ["old", "reply"])
        XCTAssertEqual(LocalTriageQueue.groupByConversation([priority, recent], grouping: true)
            .map(\.threadId), ["recent", "priority"])
    }

    func testThreadRemovalsClearPresentedMembersOnlyInTheirMailbox() {
        let group = item("thread", [message("old", from: "Sam", minutesAgo: 2),
            message("new", from: "Priya", minutesAgo: 1, unread: false)])
        let other = item("thread", [message("old", from: "Other", minutesAgo: 3)],
            account: "other@example.test")
        for verb in ["archive_message"] {
            XCTAssertEqual(LocalTriageQueue.unreadRemovalIDs(id: "old", verb: verb,
                account: group.account, presented: [other, group]), ["new", "old"])
            XCTAssertEqual(LocalTriageQueue.unreadRemovalIDs(id: "old", verb: verb,
                account: group.account, presented: [other]), ["old"])
        }
        XCTAssertEqual(LocalTriageQueue.unreadRemovalIDs(id: "old", verb: "mark_spam",
            account: group.account, presented: [group]), ["old"])
    }

    func testAllReadConversationHasReadableStandingNote() throws {
        let group = item("thread", [message("old", from: "Sam", minutesAgo: 2, unread: false),
            message("new", from: "Priya", minutesAgo: 1, unread: false)])
        let standing = try XCTUnwrap(LocalTriageQueue.threadStanding(group, scope: .all))
        let note = try XCTUnwrap(standing["note"] as? String)
        XCTAssertTrue(note.contains("2 messages they have already read"))
        XCTAssertFalse(note.contains("0 new"))
        XCTAssertFalse(note.contains("from ,"))
        XCTAssertEqual(standing["senders"] as? [String], ["Sam", "Priya"])
    }

    /// A single selected message inside a longer Gmail thread still owes the summary the
    /// recording asks for — "a summary of the conversation and its latest reply" — and must
    /// not be announced as a thread. Reported 2026-09-09: it named the thread and stopped.
    func testOneMessageOfALongerConversationAsksForASummaryNotALabel() throws {
        var alone = item("thread", [message("latest", from: "Raghav", minutesAgo: 1)])
        alone.threadMessageCount = 2
        let note = try XCTUnwrap(LocalTriageQueue.threadStanding(alone, scope: .unread)?["note"] as? String)
        XCTAssertTrue(note.contains("Open with the mail"), "the mail comes before the conversation")
        XCTAssertTrue(note.contains("summarising the earlier messages and this latest reply together"))
        XCTAssertTrue(note.contains("never say how many messages it holds"))

        // A standalone message with nothing behind it gets no conversation note at all.
        let standalone = item("thread", [message("only", from: "Raghav", minutesAgo: 1)])
        XCTAssertNil(LocalTriageQueue.threadStanding(standalone, scope: .unread),
                     "one message and one thread is not a conversation")
    }

    func testRestorePrioritizesFreshMailAndKeepsCurrentContinuationSeparate() {
        let current = item("thread", [message("current", from: "Sam", minutesAgo: 10)])
        let tail = item("tail", [message("tail", from: "Dana", minutesAgo: 9)])
        let fresh = item("fresh", [message("fresh", from: "Priya", minutesAgo: 1)])
        let continuation = item("thread", [message("continuation", from: "Sam", minutesAgo: 2)])
        let result = LocalTriageQueue.restoringPage([fresh, continuation], to: [current, tail],
            currentID: current.id, currentAccount: current.account, grouping: true)
        XCTAssertEqual(result.map(\.id), ["current", "fresh", "continuation", "tail"])
        XCTAssertEqual(result.first?.ids, ["current"])
    }

    func testRestoreMergesFreshAheadMembersAndScopesCurrentByMailbox() {
        let other = item("thread", [message("current", from: "Other", minutesAgo: 20)],
            account: "other@example.test")
        let current = item("thread", [message("current", from: "Sam", minutesAgo: 10)])
        let tail = item("tail", [message("tail", from: "Dana", minutesAgo: 9)])
        // Same sender as `tail`, so the fresh member merges into it rather than becoming
        // its own stop — this test is about restore order, not sender boundaries.
        let reply = item("tail", [message("reply", from: "Dana", minutesAgo: 1)])
        let continuation = item("thread", [message("continuation", from: "Sam", minutesAgo: 2)])
        let result = LocalTriageQueue.restoringPage([reply, continuation], to: [other, current, tail],
            currentID: current.id, currentAccount: current.account, grouping: true)
        XCTAssertEqual(result.map(\.id), ["current", "reply", "continuation", "current"])
        XCTAssertEqual(result.first?.account, current.account)
        XCTAssertEqual(result.first?.ids, ["current"])
        XCTAssertEqual(result[1].ids, ["tail", "reply"])
        XCTAssertEqual(result.last?.account, other.account)
    }

    func testUnsubscribeSenderLookupIsMailboxScoped() {
        let first = item("thread", [message("same", from: "Sam", minutesAgo: 1)])
        let second = item("thread", [message("same", from: "Priya", minutesAgo: 1)], account: "other@example.test")
        XCTAssertEqual(LocalTriageQueue.sender(ofId: "same", account: second.account, in: [first, second]), "Priya")
        XCTAssertEqual(LocalTriageQueue.sender(ofId: "same", account: first.account, in: [second, first]), "Sam")
        XCTAssertNil(LocalTriageQueue.sender(ofId: "same", account: nil, in: [first, second]))
        XCTAssertNil(LocalTriageQueue.sender(ofId: "same", account: "missing@example.test", in: [first, second]))
    }

    private func withGrouping(_ on: Bool, _ body: () throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: ThreadQueue.storageKey)
        defaults.set(on, forKey: ThreadQueue.storageKey)
        defer {
            if let previous { defaults.set(previous, forKey: ThreadQueue.storageKey) }
            else { defaults.removeObject(forKey: ThreadQueue.storageKey) }
        }
        try body()
    }

    /// Three unread replies from **one** sender are one stop. Three from three people are
    /// three, which `testEachUnreadSenderInAThreadIsItsOwnStop` covers — the recording:
    /// "sender A… B… C… So these are three separate conversations."
    func testThreeRepliesFromOneSenderBecomeOneConversation() throws {
        try withGrouping(true) {
            let priya = "Priya Raman <priya@northwind.test>"
            let page = [
                item("thr-update", [message("m-priya", from: priya, minutesAgo: 1)]),
                item("thr-vendor", [message("m-oa", from: "Vendor <no@vendor.test>", minutesAgo: 2)]),
                item("thr-update", [message("m-sam", from: priya, minutesAgo: 3)]),
                item("thr-update", [message("m-dana", from: priya, minutesAgo: 4)]),
            ]

            let grouped = LocalTriageQueue.groupByConversation(page)

            XCTAssertEqual(grouped.count, 2, "three replies from one sender collapse into one item")
            let conversation = try XCTUnwrap(grouped.first { $0.threadId == "thr-update" })
            XCTAssertEqual(conversation.conversation.count, 3)
            XCTAssertEqual(
                conversation.id, "m-priya",
                "the item is pinned to the newest message of the conversation")
            XCTAssertEqual(
                conversation.conversation.map(\.id), ["m-dana", "m-sam", "m-priya"],
                "and its messages read oldest first")
        }
    }

    /// `docs/email-thread-behavior.md`, from the recording: "A reply by the owner or a
    /// secretary stays inside that conversation; changing sender does not itself create a new
    /// group." Vivek's back-and-forth including Nate's reply is one conversation.
    func testADifferentSenderInTheSameChainStaysOneStop() throws {
        try withGrouping(true) {
            let page = [
                item("thr-update", [message("m-priya", from: "Priya Raman <priya@northwind.test>", minutesAgo: 1)]),
                item("thr-update", [message("m-sam", from: "Sam <sam@harbourline.test>", minutesAgo: 3)]),
                item("thr-update", [message("m-dana", from: "Dana <dana@northwind.test>", minutesAgo: 4)]),
            ]

            let grouped = LocalTriageQueue.groupByConversation(page)

            XCTAssertEqual(grouped.count, 1, "three senders on one chain are one conversation")
            XCTAssertEqual(grouped.first?.conversation.count, 3)
            XCTAssertEqual(grouped.first?.id, "m-priya", "named by its latest reply")
        }
    }

    func testTheSameConversationInTwoInboxesStaysTwoItems() throws {
        try withGrouping(true) {
            // Gmail thread ids are per mailbox, so this is two conversations and a reply to
            // either has to leave from its own address.
            let one = message("m-a", from: "Priya <priya@northwind.test>", minutesAgo: 1)
            let mine = item("thr-update", [one])
            let theirs = item("thr-update", [one], account: "second@kiloforge.test")

            XCTAssertEqual(LocalTriageQueue.groupByConversation([mine, theirs]).count, 2)
        }
    }

    func testGroupingIsOffUntilTheFlagIsOn() throws {
        try withGrouping(false) {
            let page = [
                item("thr-update", [message("m-priya", from: "Priya <priya@northwind.test>", minutesAgo: 1)]),
                item("thr-update", [message("m-sam", from: "Sam <sam@harbourline.test>", minutesAgo: 3)]),
            ]
            XCTAssertEqual(
                LocalTriageQueue.groupByConversation(page).count, 2,
                "with the flag off the queue is one item per message, exactly as it shipped")
        }
    }

    func testActingOnAnyMessageReachesTheConversation() {
        let conversation = item("thr-update", [
            message("m-dana", from: "Dana <dana@northwind.test>", minutesAgo: 4),
            message("m-sam", from: "Sam <sam@harbourline.test>", minutesAgo: 3),
            message("m-priya", from: "Priya <priya@northwind.test>", minutesAgo: 1),
        ])

        XCTAssertTrue(conversation.holds("m-priya"), "the newest message is the item's own id")
        XCTAssertTrue(
            conversation.holds("m-dana"),
            "and so is the oldest — acting on it must not leave the cursor standing still")
        XCTAssertFalse(conversation.holds("m-elsewhere"))
        XCTAssertEqual(conversation.ids.count, 3)
    }

    func testCountsStayInMessages() {
        let conversation = item("thr-update", [
            message("m-dana", from: "Dana <dana@northwind.test>", minutesAgo: 4),
            message("m-sam", from: "Sam <sam@harbourline.test>", minutesAgo: 3),
            message("m-priya", from: "Priya <priya@northwind.test>", minutesAgo: 1),
        ])
        XCTAssertEqual(
            conversation.unreadCount, 3,
            "a conversation is worth its unread mail, so the mailbox total and the queue agree")

        let single = item("thr-solo", [message("m-solo", from: "A <a@x.test>", minutesAgo: 1)])
        XCTAssertEqual(single.unreadCount, 1)
    }

    func testReadMessagesRideAlongButAreNotCounted() {
        let mixed = item("thr-update", [
            message("m-old", from: "Dana <dana@northwind.test>", minutesAgo: 9, unread: false),
            message("m-new", from: "Sam <sam@harbourline.test>", minutesAgo: 1),
        ])
        XCTAssertEqual(mixed.conversation.count, 2, "the read message is carried as context")
        XCTAssertEqual(
            mixed.unreadCount, 1,
            "but only the unread one is mail waiting, so it is the only one counted")
    }

    func testAConversationWithoutMessagesDecodesAsOneMessage() throws {
        // A snapshot written before grouping shipped. It must read exactly as it did then.
        let json = """
        {"account":"you@kiloforge.test","threadId":"thr-1","id":"m-1",
         "from":"A <a@x.test>","subject":"Hello","date":"2026-09-02T14:00:00Z",
         "snippet":"Hi","internalDate":1788000000000,"markedRead":false}
        """
        let old = try JSONDecoder().decode(
            LocalTriageQueue.Item.self, from: Data(json.utf8))

        XCTAssertEqual(old.conversation.count, 1)
        XCTAssertEqual(old.ids, ["m-1"])
        XCTAssertEqual(old.unreadCount, 1)
        XCTAssertTrue(old.holds("m-1"))
    }
    func testRestoredConversationSplitsWhenFlagIsDisabled() throws {
        try withGrouping(false) {
            let grouped = item("thread", [
                message("older", from: "Sam", minutesAgo: 2),
                message("newer", from: "Priya", minutesAgo: 1),
            ])
            let result = LocalTriageQueue.groupByConversation([grouped])
            XCTAssertEqual(Set(result.map(\.id)), ["older", "newer"])
            XCTAssertTrue(result.allSatisfy { $0.conversation.count == 1 })
        }
    }

    func testOverlappingPagesDeduplicateMembers() throws {
        try withGrouping(true) {
            // One sender, so the overlap has a single group to deduplicate into.
            let older = message("older", from: "Sam", minutesAgo: 2)
            let newer = message("newer", from: "Sam", minutesAgo: 1)
            let result = LocalTriageQueue.groupByConversation([
                item("thread", [newer]), item("thread", [older, newer]),
            ])
            XCTAssertEqual(result.count, 1)
            XCTAssertEqual(result.first?.ids, ["older", "newer"])
        }
    }

    func testPartialSweepReplacesRepresentativeAndRemovesOnlyMatchedMembers() throws {
        let older = message("older", from: "Sam", minutesAgo: 2)
        let newer = message("newer", from: "Priya", minutesAgo: 1)
        let result = LocalTriageQueue.gmailEligible(
            [item("thread", [older, newer])], dealtWithThisWalk: [LocalTriageQueue.messageKey(account: "you@kiloforge.test", id: "newer")])
        let remaining = try XCTUnwrap(result.first)
        XCTAssertEqual(remaining.ids, ["older"])
        XCTAssertEqual(remaining.id, "older")
        XCTAssertEqual(remaining.from, "Sam")
        XCTAssertEqual(remaining.unreadCount, 1)
    }

    func testOnlyHandledMessagesAreSuppressedInTheirMailbox() {
        let member = message("new-id", from: "Sam", minutesAgo: 1)
        let page = [
            item("thread", [member]),
            item("thread", [member], account: "other@kiloforge.test"),
        ]
        withGrouping(true) {
            let result = LocalTriageQueue.gmailEligible(
                page, dealtWithThisWalk: [LocalTriageQueue.messageKey(account: "you@kiloforge.test", id: "new-id")])
            XCTAssertEqual(result.map(\.account), ["other@kiloforge.test"])
        }
        withGrouping(false) {
            XCTAssertEqual(LocalTriageQueue.gmailEligible(
                page, dealtWithThisWalk: ["thread:you@kiloforge.test|thread"]).count, 2)
        }
    }

    func testOlderReplyIDResolvesToConversationThread() {
        let grouped = item("thread", [
            message("older", from: "Sam", minutesAgo: 2),
            message("newer", from: "Priya", minutesAgo: 1),
        ])
        XCTAssertEqual(LocalTriageQueue.resolvedReplyThreadId("older", in: [grouped]), "thread")
    }

    func testNamedSweepUsesOlderSenderInsteadOfNewestRepresentative() {
        let grouped = item("thread", [
            message("older", from: "Marcus Jones <marcus@one.test>", minutesAgo: 2),
            message("newer", from: "Priya Raman <priya@two.test>", minutesAgo: 1),
        ])
        XCTAssertEqual(LocalTriageQueue.dispatchSweepScope(
            task: "Archive all from Marcus", item: grouped)?.sender, "marcus@one.test")
        XCTAssertNil(LocalTriageQueue.dispatchSweepScope(task: "Archive all from them", item: grouped))
    }

    func testSweepSenderRequiresWholeNameOrExactAddress() {
        let grouped = item("thread", [
            message("older", from: "Sam <sam@one.test>", minutesAgo: 2),
            message("newer", from: "Priya <priya@two.test>", minutesAgo: 1),
        ])
        for task in ["Archive all sample receipts", "Archive all sam@one.test.evil receipts"] {
            XCTAssertNil(LocalTriageQueue.dispatchSweepScope(task: task, item: grouped))
        }
        for task in ["Archive all from Sam", "Archive all emails from sam@one.test"] {
            XCTAssertEqual(LocalTriageQueue.dispatchSweepScope(task: task, item: grouped)?.sender, "sam@one.test")
        }
    }

    func testCleanupMustCoverEveryConversationMember() throws {
        let sam = message("sam", from: "Sam <sam@one.test>", minutesAgo: 2)
        let priya = message("priya", from: "Priya <priya@two.test>", minutesAgo: 1)
        let sameSender = message("new", from: "Sam <sam@one.test>", minutesAgo: 1)
        let partial = EmailCleanupDecision(category: .promotions, action: .archive,
            senderInboxCount: 1, atLeast: false, matchingMessageIDs: ["sam"])
        let complete = EmailCleanupDecision(category: .promotions, action: .archive,
            senderInboxCount: 3, atLeast: false, matchingMessageIDs: ["sam", "priya", "new"])
        let mixed = item("thread", [sam, priya])
        XCTAssertFalse(LocalTriageQueue.cleanupCoversConversation(mixed, decision: complete))
        let homogeneous = item("thread", [sam, sameSender])
        XCTAssertFalse(LocalTriageQueue.cleanupCoversConversation(homogeneous, decision: partial))
        XCTAssertTrue(LocalTriageQueue.cleanupCoversConversation(homogeneous, decision: complete))
        let remaining = try XCTUnwrap(mixed.keeping([sam]))
        XCTAssertTrue(LocalTriageQueue.cleanupCoversConversation(remaining, decision: partial))
        XCTAssertFalse(LocalTriageQueue.cleanupCoversConversation(try XCTUnwrap(mixed.keeping([priya])), decision: partial))
    }

    func testReadOnlyConversationHasNoNewMail() {
        let grouped = item("thread", [message("read", from: "Sam", minutesAgo: 1, unread: false)])
        XCTAssertEqual(grouped.unreadCount, 0)
    }

    func testPageRefillMergesAnExistingConversationWithoutMovingOtherItems() throws {
        try withGrouping(true) {
            // One sender on the thread, so the refill has a group to merge into.
            let newest = item("thread", [message("new", from: "Priya", minutesAgo: 1)])
            let unrelated = item("other", [message("other", from: "Dana", minutesAgo: 2)])
            let older = item("thread", [message("old", from: "Priya", minutesAgo: 3)])
            let result = LocalTriageQueue.appendingPage([older], to: [newest, unrelated])
            XCTAssertEqual(result.map(\.id), ["new", "other"])
            XCTAssertEqual(result.first?.ids, ["old", "new"])
        }
    }


    func testCurrentGroupStaysStableAndRefillRetainsUnseenMembers() {
        let current = item("thread", [message("new", from: "Priya", minutesAgo: 1)])
        let older = item("thread", [message("old", from: "Sam", minutesAgo: 3)])
        let first = LocalTriageQueue.appendingPage(
            [current, older], to: [current], position: 1, grouping: true)
        XCTAssertEqual(first.map(\.ids), [["new"], ["old"]])
        let retry = LocalTriageQueue.appendingPage(
            [older], to: first, position: 2, grouping: true)
        XCTAssertEqual(retry.map(\.ids), [["new"], ["old"]])
        XCTAssertEqual(LocalTriageQueue.gmailEligible(
            [older], dealtWithThisWalk: ["thread:you@kiloforge.test|thread"]).first?.ids, ["old"])
    }

    func testRefillDedupeKeepsEqualMessageIDsInDifferentMailboxes() {
        let member = message("same", from: "Sam", minutesAgo: 1)
        let first = item("thread", [member])
        let other = item("thread", [member], account: "other@kiloforge.test")
        let result = LocalTriageQueue.appendingPage(
            [first, other], to: [first], position: 1, grouping: true)
        XCTAssertEqual(result.map(\.account), [first.account, other.account])
    }

    func testResumeRetainsEqualIDsInDifferentMailboxes() {
        let member = message("same", from: "Sam", minutesAgo: 1)
        let one = item("thread", [member])
        let other = item("thread", [member], account: "other@kiloforge.test")
        let result = LocalTriageQueue.mergeForResume(
            currentID: "same", eligibleSaved: [one, other], fresh: [one], currentAccount: other.account)
        XCTAssertEqual(result.map(\.account), [other.account, one.account])
    }

    func testExplicitGroupingModeOverridesChangedProfile() {
        withGrouping(false) {
            let page = [
                item("thread", [message("one", from: "Sam", minutesAgo: 2)]),
                item("thread", [message("two", from: "Sam", minutesAgo: 1)]),
            ]
            XCTAssertEqual(LocalTriageQueue.groupByConversation(page, grouping: true).count, 1)
            XCTAssertEqual(LocalTriageQueue.appendingPage(
                page, to: [], grouping: true).count, 1)
        }
    }

    func testRestoreDropsAStaleOlderMemberAndUsesFreshContent() {
        let saved = item("thread", [
            message("old", from: "Sam", minutesAgo: 2),
            message("new", from: "Priya", minutesAgo: 1),
        ])
        let rows = ["old", "new"].map { id in
            MailStore.Message(user_id: "test-user", id: id, account: "you@kiloforge.test", threadId: "thread",
                sender: "Fresh sender", recipient: nil, subject: "Fresh subject", snippet: "Fresh snippet",
                internalDate: 10, cachedAt: Date())
        }
        let result = LocalTriageQueue.refreshedSavedItems(
            [saved], rows: rows, eligibleIDs: ["new"])
        XCTAssertEqual(result.flatMap(\.ids), ["new"])
        XCTAssertEqual(result.first?.snippet, "Fresh snippet")
    }

    func testRestoreHydrationPreservesSavedFactsWhenCacheUnavailable() async {
        var saved = item("thread", [message("read", from: "Sam", minutesAgo: 2, unread: false),
            message("unread", from: "Priya", minutesAgo: 1)])
        saved.hasDraft = true
        saved.coachingCounted = true
        let rows = saved.conversation.map {
            MailStore.Message(user_id: "test-user", id: $0.id, account: saved.account, threadId: saved.threadId,
                sender: "Fresh sender", recipient: nil, subject: "Fresh subject", snippet: "Fresh snippet",
                internalDate: $0.internalDate, cachedAt: Date())
        }
        let hydrated = LocalTriageQueue.refreshedSavedItems(
            [saved], rows: rows, eligibleIDs: Set(saved.ids))
        let refreshed = await LocalTriageQueue.refreshFacts(hydrated, store: MailStore(database: nil, userId: "test-user"))
        XCTAssertEqual(refreshed.flatMap { $0.conversation.map(\.unread) }, [false, true])
        XCTAssertTrue(refreshed.allSatisfy { $0.hasDraft == true && $0.coachingCounted == true })
        XCTAssertTrue(refreshed.allSatisfy { $0.snippet == "Fresh snippet" })
    }

    func testRefillDoesNotMergeFreshMailIntoCountedContinuation() {
        let live = item("other", [message("live", from: "Sam", minutesAgo: 1)])
        var counted = item("thread", [message("counted", from: "Priya", minutesAgo: 2)])
        counted.coachingCounted = true
        let fresh = item("thread", [message("fresh", from: "Dana", minutesAgo: 3)])
        let result = LocalTriageQueue.appendingPage([fresh], to: [live, counted], position: 1, grouping: true)
        XCTAssertEqual(result.map(\.ids), [["live"], ["counted"], ["fresh"]])
        XCTAssertEqual(result[1].coachingCounted, true)
        XCTAssertNil(result.last?.coachingCounted)
        let unseen = result.dropFirst().filter { $0.coachingCounted != true }.flatMap(\.ids)
        XCTAssertEqual(unseen, ["fresh"])
        let replay = LocalTriageQueue.appendingPage([fresh, counted], to: result, position: 1, grouping: true)
        XCTAssertEqual(replay.map(\.ids), result.map(\.ids))
    }

    func testUnavailableCachePreservesEachGmailUnreadFlag() async {
        var saved = item("thread", [message("read", from: "Sam", minutesAgo: 2, unread: false),
            message("unread", from: "Priya", minutesAgo: 1)])
        saved.hasDraft = true
        let store = MailStore(database: nil, userId: "test-user")
        let state = await store.unreadState(among: saved.ids)
        XCTAssertNil(state)
        let result = await LocalTriageQueue.refreshFacts([saved], store: store)
        XCTAssertEqual(result.first?.conversation.map(\.unread), [false, true])
        XCTAssertEqual(result.first?.hasDraft, true)
    }

    func testFailedUnreadQueryDiffersFromSuccessfulAllReadQuery() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try DatabasePool(path: directory.appendingPathComponent("mail.sqlite").path)
        defer {
            try? database.close()
            try? FileManager.default.removeItem(at: directory)
        }
        let store = MailStore(database: database, userId: "test-user")
        var saved = item("thread", [message("read", from: "Sam", minutesAgo: 2, unread: false),
            message("unread", from: "Priya", minutesAgo: 1)])
        saved.hasDraft = true
        let failed = await store.unreadState(among: saved.ids)
        XCTAssertNil(failed)
        let preserved = await LocalTriageQueue.refreshFacts([saved], store: store)
        XCTAssertEqual(preserved.first?.conversation.map(\.unread), [false, true])
        XCTAssertEqual(preserved.first?.hasDraft, true)
        try await database.write { db in
            try MailStore.createUserScopedSchema(db)
        }
        let known = await store.unreadState(among: saved.ids)
        XCTAssertEqual(known, [])
        let refreshed = await LocalTriageQueue.refreshFacts([saved], store: store)
        XCTAssertEqual(refreshed.first?.conversation.map(\.unread), [false, false])
        XCTAssertEqual(refreshed.first?.hasDraft, false)
    }

    func testConversationSendersAreUniqueInFirstSeenOrder() throws {
        for unread in [true, false] {
            let saved = item("thread", [message("a", from: "Sam", minutesAgo: 3, unread: unread),
                message("b", from: "Priya", minutesAgo: 2, unread: unread),
                message("c", from: "Sam", minutesAgo: 1, unread: unread)])
            let standing = try XCTUnwrap(LocalTriageQueue.threadStanding(saved, scope: .all))
            XCTAssertEqual(standing["senders"] as? [String], ["Sam", "Priya"])
            XCTAssertFalse((standing["note"] as? String)?.contains("Sam, Priya and Sam") == true)
            XCTAssertEqual(saved.conversation.map(\.from), ["Sam", "Priya", "Sam"])
        }
    }

    func testCachedUnreadAndDraftFactsReachConversation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try DatabasePool(path: directory.appendingPathComponent("mail.sqlite").path)
        defer {
            try? database.close()
            try? FileManager.default.removeItem(at: directory)
        }
        try await database.write { db in
            try MailStore.createUserScopedSchema(db)
            for id in ["old", "new"] {
                try MailStore.Message(user_id: "test-user", id: id, account: "you@kiloforge.test", threadId: "thread",
                    sender: "Sender", recipient: nil, subject: "Subject", snippet: "Snippet",
                    internalDate: 1, cachedAt: Date()).insert(db)
            }
            try MailStore.Label(user_id: "test-user", messageId: "new", account: "you@kiloforge.test",
                                label: "UNREAD").insert(db)
            try MailStore.Draft(user_id: "test-user", id: "draft", messageId: "draft-message", threadId: "thread",
                account: "you@kiloforge.test", recipient: nil, subject: nil, snippet: nil,
                internalDate: 1, cachedAt: Date()).insert(db)
        }
        let saved = item("thread", [
            message("old", from: "Sam", minutesAgo: 2),
            message("new", from: "Priya", minutesAgo: 1),
        ])
        let result = await LocalTriageQueue.refreshFacts([saved], store: MailStore(database: database, userId: "test-user"))
        XCTAssertEqual(result.first?.unreadCount, 1)
        XCTAssertEqual(result.first?.conversation.first?.unread, false)
        XCTAssertEqual(result.first?.hasDraft, true)
    }

    func testDraftListingIncludesOlderPagesAndDeduplicatesOverlap() async throws {
        var tokens: [String?] = []
        let refs = try await BackgroundMailRefresh.allDraftReferences { token in
            tokens.append(token)
            let start = token.flatMap(Int.init) ?? 0
            let ids = start..<(start + 100)
            let page = ids.map { GmailAPI.DraftRef(id: "draft-\($0)", message: nil) }
            return GmailAPI.DraftList(drafts: page, nextPageToken: start < 200 ? String(start + 100) : nil)
        }
        XCTAssertEqual(tokens.count, 3)
        XCTAssertEqual(refs.count, 300)
        XCTAssertEqual(refs.last?.id, "draft-299")
        var page = 0
        let overlap = try await BackgroundMailRefresh.allDraftReferences { _ in
            page += 1
            return GmailAPI.DraftList(drafts: [.init(id: "same", message: nil)], nextPageToken: page == 1 ? "next" : nil)
        }
        XCTAssertEqual(overlap.map(\.id), ["same"])
    }

    func testDraftListingRejectsRepeatedPageToken() async {
        do {
            _ = try await BackgroundMailRefresh.allDraftReferences { _ in
                GmailAPI.DraftList(drafts: [], nextPageToken: "repeat")
            }
            XCTFail("An incomplete repeating listing must not replace the draft cache")
        } catch {
            XCTAssertEqual((error as NSError).domain, "GmailDraftSync")
        }
    }

    func testSelectedDraftLookupFindsOlderDraftAndIsMailboxScoped() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try DatabasePool(path: directory.appendingPathComponent("mail.sqlite").path)
        defer {
            do { try database.close(); try FileManager.default.removeItem(at: directory) }
            catch { XCTFail("Could not remove draft test database: \(error)") }
        }
        try await database.write { db in
            try MailStore.createUserScopedSchema(db)
            try MailStore.createDraftThreadIndex(db)
            for index in 0..<301 {
                try MailStore.Draft(user_id: "test-user", id: "d-\(index)", messageId: "m-\(index)", threadId: "t-\(index)",
                    account: "me@example.test", recipient: nil, subject: nil, snippet: nil,
                    internalDate: Int64(index), cachedAt: Date()).insert(db)
            }
            let plan = try Row.fetchAll(db,
                sql: "EXPLAIN QUERY PLAN SELECT DISTINCT threadId FROM mail_draft WHERE account = ? AND threadId IN (?)",
                arguments: ["me@example.test", "t-0"])
            XCTAssertTrue(plan.contains { ($0["detail"] as String).contains("mail_draft_account_thread_idx") })
        }
        let store = MailStore(database: database, userId: "test-user")
        let own = await store.draftThreadIDs(account: "me@example.test", among: ["t-0", "missing"])
        let other = await store.draftThreadIDs(account: "other@example.test", among: ["t-0"])
        XCTAssertEqual(own, ["t-0"])
        XCTAssertEqual(other, [])
    }

    func testLegacyHandledMigrationUsesRecordedMailboxOwnership() {
        let owned = item("thread", [message("known", from: "Sam", minutesAgo: 1)])
        let scoped = LocalTriageQueue.messageKey(account: "other@example.test", id: "scoped")
        let keys = LocalTriageQueue.restoredHandledKeys(["known", "unknown", scoped], items: [owned],
            accounts: [owned.account, "other@example.test"])
        XCTAssertEqual(keys, [LocalTriageQueue.messageKey(account: owned.account, id: "known"), scoped])
        let ambiguous = LocalTriageQueue.restoredHandledKeys(["known"],
            items: [owned, item("other", [message("known", from: "Priya", minutesAgo: 1)], account: "other@example.test")],
            accounts: [owned.account, "other@example.test"])
        XCTAssertTrue(ambiguous.isEmpty)
    }

    func testLiveLabelFactsSurviveFailedCacheWriteAndStaleDuplicate() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try DatabasePool(path: directory.appendingPathComponent("mail.sqlite").path)
        defer {
            do { try database.close(); try FileManager.default.removeItem(at: directory) }
            catch { XCTFail("Could not remove live-page test database: \(error)") }
        }
        try await database.write { db in
            try MailStore.createUserScopedSchema(db)
            try db.execute(sql: "CREATE TRIGGER fail_cache BEFORE INSERT ON \(MailStore.Message.databaseTableName) BEGIN SELECT RAISE(FAIL, 'forced write failure'); END")
        }
        let store = MailStore(database: database, userId: "test-user")
        let json = #"{"id":"live","threadId":"thread","labelIds":["INBOX","UNREAD"],"internalDate":"20","snippet":"Fresh Gmail content"}"#
        let detail = try JSONDecoder().decode(GmailAPI.MessageDetail.self, from: Data(json.utf8))
        let ingest = MailStore.Ingest(detail: detail, account: "you@kiloforge.test")
        await store.cache([ingest])
        let cachedUnread = await store.unreadState(among: ["live"])
        XCTAssertEqual(cachedUnread, [])
        let fetched = LocalTriageQueue.liveItem(from: ingest)
        let stale = item("thread", [message("live", from: "Sam", minutesAgo: 1, unread: false)])
        let merged = await LocalTriageQueue.mergingLivePage([fetched], with: [stale], store: store)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.unreadCount, 1)
        XCTAssertEqual(merged.first?.snippet, "Fresh Gmail content")
        let readJSON = json.replacingOccurrences(of: #","UNREAD""#, with: "")
        let readDetail = try JSONDecoder().decode(GmailAPI.MessageDetail.self, from: Data(readJSON.utf8))
        let read = LocalTriageQueue.liveItem(from: MailStore.Ingest(detail: readDetail, account: "you@kiloforge.test"))
        let readPage = await LocalTriageQueue.mergingLivePage([read], with: [fetched], store: store)
        XCTAssertEqual(readPage.first?.unreadCount, 0)
    }

    func testPendingReadContinuationRequiresInboxMembership() {
        var pending = item("thread", [message("read", from: "Sam", minutesAgo: 1, unread: false)])
        pending.unresolvedContinuation = true
        let row = MailStore.Message(user_id: "test-user", id: "read", account: pending.account, threadId: pending.threadId,
            sender: pending.from, recipient: nil, subject: pending.subject, snippet: pending.snippet,
            internalDate: pending.internalDate, cachedAt: Date())
        let kept = LocalTriageQueue.refreshedSavedItems([pending], rows: [row], eligibleIDs: [],
            requeuedInboxIDs: ["read"])
        XCTAssertEqual(kept.first?.unresolvedContinuation, true)
        XCTAssertEqual(kept.first?.unreadCount, 0)
        XCTAssertEqual(LocalTriageQueue.messageCount(pending, scope: .unread, grouping: true), 1)
        XCTAssertTrue((LocalTriageQueue.threadStanding(pending, scope: .unread)?["note"] as? String)?.contains("already read") == true)
        let gone = LocalTriageQueue.refreshedSavedItems([pending], rows: [row], eligibleIDs: [],
            requeuedInboxIDs: [])
        XCTAssertTrue(gone.isEmpty)
    }

    func testCoachingServesCrossedThresholdsWithoutSkippingTheFirstInterlude() {
        XCTAssertNil(LocalTriageQueue.nextCoachingCheckpoint(handled: 11, last: 0))
        XCTAssertEqual(LocalTriageQueue.nextCoachingCheckpoint(handled: 14, last: 0), 1)
        XCTAssertEqual(LocalTriageQueue.nextCoachingCheckpoint(handled: 27, last: 0), 1)
        XCTAssertEqual(LocalTriageQueue.nextCoachingCheckpoint(handled: 27, last: 1), 2)
        XCTAssertNil(LocalTriageQueue.nextCoachingCheckpoint(handled: 27, last: 2))
    }

    func testDealtWithLedgerIsIsolatedBySignedInUser() throws {
        let first = "test-" + UUID().uuidString
        let second = "test-" + UUID().uuidString
        defer {
            try? FileManager.default.removeItem(at: DealtWithLog.url(userID: first))
            try? FileManager.default.removeItem(at: DealtWithLog.url(userID: second))
        }
        let now = Date()
        let key = "thread:shared@example.test|thread"
        DealtWithLog.save([key: now.timeIntervalSince1970], userID: first, now: now)
        XCTAssertNotNil(DealtWithLog.load(userID: first, now: now)[key])
        XCTAssertTrue(DealtWithLog.load(userID: second, now: now).isEmpty)
        let record = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: DealtWithLog.url(userID: first))) as? [String: Any])
        XCTAssertEqual(record["user_id"] as? String, first)
    }

}
