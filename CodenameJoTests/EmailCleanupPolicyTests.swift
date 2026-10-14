import Foundation
import GRDB
import XCTest
@testable import CodenameJo

final class EmailCleanupPolicyTests: XCTestCase {
    func testGeneratedCleanupRecognitionKeepsExactRestrictions() throws {
        let item = EmailCleanupInput(account: "owner@example.test", id: "message",
                                     from: "Shop <offers@shop.test>")
        for (category, action) in [(GmailMailCategory.promotions, EmailCleanupDecision.Action.unsubscribe),
                                   (.promotions, .archive), (.purchases, .archive)] {
            let decision = EmailCleanupDecision(category: category, action: action, senderInboxCount: 10, atLeast: false)
            let dispatch = try XCTUnwrap(EmailCleanupPolicy.cleanupPayload(item: item, decision: decision)?["dispatch"] as? [String: Any])
            let task = try XCTUnwrap(dispatch["task"] as? String)
            XCTAssertEqual(EmailCleanupPolicy.generatedCleanupCategory(task: task, item: item), category)
            for modified in [task + " Also archive from:other.test.",
                             task.replacingOccurrences(of: "from:offers@shop.test", with: "from:shop.test"),
                             task.replacingOccurrences(of: "owner@example.test", with: "other@example.test"),
                             task.replacingOccurrences(of: "in:inbox", with: "in:inbox older_than:1y")] {
                XCTAssertNil(EmailCleanupPolicy.generatedCleanupCategory(task: modified, item: item))
            }
        }
    }

    func testPurchasesStartAtThreeAndPromotionsStayAtFive() {
        let item = EmailCleanupInput(
            account: "owner@example.test", id: "message-threshold",
            from: "Amazon <auto-confirm@amazon.com>")

        for category in [GmailMailCategory.promotions, .purchases] {
            for count in 0...6 {
                let decision = EmailCleanupDecision(
                    category: category, action: .archive,
                    senderInboxCount: count, atLeast: false)
                let payload = EmailCleanupPolicy.cleanupPayload(item: item, decision: decision)
                XCTAssertEqual(payload != nil, count >= (category == .purchases ? 3 : 5),
                               "\(category) at \(count)")
                if let payload {
                    XCTAssertEqual(payload["requiresApproval"] as? Bool, true)
                    XCTAssertEqual(payload["senderInboxCount"] as? Int, count)
                    XCTAssertEqual(payload["account"] as? String, item.account)
                    XCTAssertEqual(payload["query"] as? String,
                                   "in:inbox category:\(category.rawValue) from:auto-confirm@amazon.com")
                }
            }
        }
    }

    func testCleanupOfferKeepsOrdinaryEmailActionsAvailable() {
        XCTAssertTrue(
            EmailCleanupPolicy.alternativeOfferSentence.contains("handle this email another way"))
        let guidance = EmailCleanupPolicy.alternativeActionGuidance
        XCTAssertTrue(guidance.contains("recommendation, never an allowlist"))
        XCTAssertTrue(guidance.contains("mark spam"))
        XCTAssertTrue(guidance.contains("unsubscribe without the offered archive"))
        XCTAssertTrue(guidance.contains("compatible combination"))
        XCTAssertTrue(guidance.contains("Never say the offer only supports"))
        XCTAssertTrue(guidance.contains("clear_existing false"))
        XCTAssertTrue(guidance.contains("then mark_spam"))
        XCTAssertTrue(guidance.contains("does not authorize the offered batch archive"))
    }

    func testPromotionsUnsubscribeDispatchAlsoArchivesMatchingBatch() throws {
        let item = EmailCleanupInput(
            account: "owner@example.test", id: "message-42",
            from: "Offers <sale@shop.example>")
        let decision = EmailCleanupDecision(
            category: .promotions, action: .unsubscribe,
            senderInboxCount: 37, atLeast: false)

        let cleanup = try XCTUnwrap(
            EmailCleanupPolicy.cleanupPayload(item: item, decision: decision))
        let dispatch = try XCTUnwrap(cleanup["dispatch"] as? [String: Any])
        let task = try XCTUnwrap(dispatch["task"] as? String)

        XCTAssertTrue(JSONSerialization.isValidJSONObject(cleanup))
        XCTAssertEqual(cleanup["action"] as? String, "unsubscribe")
        XCTAssertEqual(cleanup["senderDisplayName"] as? String, "Shop")
        XCTAssertEqual(dispatch["account"] as? String, item.account)
        XCTAssertEqual(dispatch["expects"] as? String, "receipt")
        XCTAssertTrue(task.contains("unsubscribe_sender"))
        XCTAssertTrue(task.contains("clear_existing true"))
        XCTAssertTrue(task.contains("clear_existing_query"))
        XCTAssertTrue(task.contains(
            "clear_existing_query \"in:inbox category:promotions from:sale@shop.example\""))
        XCTAssertTrue(task.contains("do not call modify_matching separately"))
        XCTAssertTrue(LocalTriageQueue.sweepsTheSender(task))
        XCTAssertFalse(LocalTriageQueue.sweepsTheSender(
            "Use unsubscribe_sender with clear_existing false."))
    }

    func testCleanupSenderDisplayNameNeverStartsWithThisSender() {
        XCTAssertEqual(
            EmailCleanupPolicy.displayName("assemblymember.lee@outreach.example"),
            "Assemblymember Lee")
        XCTAssertEqual(
            EmailCleanupPolicy.displayName("news@lollapalooza.com"),
            "Lollapalooza")
        XCTAssertEqual(EmailCleanupPolicy.displayName("news@bbc.co.uk"), "Bbc")
    }

    func testPurchaseOfferNamesTheMerchant() throws {
        for from in [
            "orders@lululemon.com",
            "\"Orders\" <orders@lululemon.com>",
            "ORDERS <store123@lululemon.com>",
            "receipts+online@mail.lululemon.com",
            "Shipping <shipping@lululemon.com>",
        ] {
            let item = EmailCleanupInput(account: "owner@example.test", id: "purchase", from: from)
            let decision = EmailCleanupDecision(
                category: .purchases, action: .archive, senderInboxCount: 10, atLeast: false)
            let payload = try XCTUnwrap(EmailCleanupPolicy.cleanupPayload(item: item, decision: decision))
            XCTAssertEqual(payload["senderDisplayName"] as? String, "Lululemon", from)
            XCTAssertEqual(payload["query"] as? String, EmailCleanupPolicy.query(category: .purchases, from: from))
            XCTAssertEqual(payload["senderInboxCount"] as? Int, 10)
        }
        XCTAssertEqual(EmailCleanupPolicy.displayName("orders@news.johnlewis.co.uk"), "Johnlewis")
        XCTAssertEqual(EmailCleanupPolicy.displayName("Lululemon Orders <orders@delivery.example>"), "Lululemon Orders")
        XCTAssertEqual(EmailCleanupPolicy.displayName("Dana Okafor <orders@shop.example>"), "Dana Okafor")
    }

    func testDispatchSweepUsesThePinnedCleanupQuery() throws {
        let task = """
        Use unsubscribe_sender with clear_existing true and clear_existing_query \
        "in:inbox category:promotions from:sale@news.shop.example".
        """
        let scope = try XCTUnwrap(LocalTriageQueue.dispatchSweepScope(
            task: task, currentFrom: "Shop <security@shop.example>"))

        XCTAssertEqual(scope.sender, "sale@news.shop.example")
        XCTAssertEqual(scope.category, .promotions)
    }

    func testCategoryDispatchPrunesAcrossPagesWithoutWideningToSender() {
        let plan = LocalTriageQueue.dispatchPrunePlan(
            category: .purchases,
            cachedIDs: ["cached-page-1", "cached-page-2"],
            enrichedIDs: ["gmail-page-2", "cached-page-2"])

        XCTAssertEqual(plan.ids, ["cached-page-1", "cached-page-2", "gmail-page-2"])
        XCTAssertFalse(plan.usesSenderFallback)

        let unknown = LocalTriageQueue.dispatchPrunePlan(
            category: .promotions, cachedIDs: nil, enrichedIDs: [])
        XCTAssertTrue(unknown.ids.isEmpty)
        XCTAssertFalse(unknown.usesSenderFallback)
    }

    func testQueueSnapshotRequiresAllConnectedGmailAccounts() {
        XCTAssertTrue(LocalTriageQueue.snapshotAccountsMatch(
            saved: ["personal@example.test", "work@example.test"],
            current: ["WORK@example.test", "PERSONAL@example.test"],
            allowsSubset: false))
        XCTAssertFalse(LocalTriageQueue.snapshotAccountsMatch(
            saved: ["personal@example.test"],
            current: ["personal@example.test", "work@example.test"],
            allowsSubset: false))
        XCTAssertTrue(LocalTriageQueue.snapshotAccountsMatch(
            saved: ["personal@example.test"],
            current: ["personal@example.test", "work@example.test"],
            allowsSubset: true))
    }

    func testCleanupCacheIsScopedToTheSignedInUser() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try DatabasePool(path: directory.appendingPathComponent("test.sqlite").path)
        let matchingIDs = try JSONEncoder().encode(["message-1"])

        try database.write { db in
            try EmailCleanupRecord.createSchema(db)
            for userId in ["user-a", "user-b"] {
                try EmailCleanupRecord(
                    userId: userId,
                    account: "owner@example.test",
                    messageId: "message-1",
                    category: GmailMailCategory.promotions.rawValue,
                    action: EmailCleanupDecision.Action.unsubscribe.rawValue,
                    senderInboxCount: 1,
                    atLeast: false,
                    matchingMessageIDsJSON: matchingIDs,
                    checkedAt: Date()).save(db)
            }
            XCTAssertEqual(try EmailCleanupRecord.fetchCount(db), 2)
        }
    }

    func testGenericSenderBatchUsesTheSendingHost() throws {
        let scope = try XCTUnwrap(LocalTriageQueue.dispatchSweepScope(
            task: "Archive all emails from LinkedIn",
            currentFrom: "LinkedIn <security-noreply@linkedin.com>"))

        XCTAssertEqual(scope.sender, "linkedin.com")
        XCTAssertNil(scope.category)
    }

    func testPurchaseArchivePinsCategorySenderAndAccount() throws {
        let item = EmailCleanupInput(
            account: "owner@example.test", id: "message-43",
            from: "Receipts <orders@shop.example>")
        let decision = EmailCleanupDecision(
            category: .purchases, action: .archive,
            senderInboxCount: 12, atLeast: true)

        let cleanup = try XCTUnwrap(
            EmailCleanupPolicy.cleanupPayload(item: item, decision: decision))
        let dispatch = try XCTUnwrap(cleanup["dispatch"] as? [String: Any])
        let task = try XCTUnwrap(dispatch["task"] as? String)

        XCTAssertEqual(cleanup["query"] as? String,
                       "in:inbox category:purchases from:orders@shop.example")
        XCTAssertEqual(cleanup["atLeast"] as? Bool, true)
        XCTAssertTrue(task.contains("modify_matching with action archive"))
        XCTAssertTrue(task.contains("account \"owner@example.test\""))
        XCTAssertTrue(task.contains("Do not widen the sender, category, query, or account"))
    }

    func testPromotionWithoutVerifiedUnsubscribeCanOfferNarrowArchiveFallback() throws {
        let item = EmailCleanupInput(
            account: "owner@example.test", id: "message-unsigned",
            from: "Offers <sale@shop.example>")
        let decision = EmailCleanupDecision(
            category: .promotions, action: .archive,
            senderInboxCount: 8, atLeast: false)

        let cleanup = try XCTUnwrap(
            EmailCleanupPolicy.cleanupPayload(item: item, decision: decision))
        let dispatch = try XCTUnwrap(cleanup["dispatch"] as? [String: Any])
        let task = try XCTUnwrap(dispatch["task"] as? String)

        XCTAssertEqual(cleanup["query"] as? String,
                       "in:inbox category:promotions from:sale@shop.example")
        XCTAssertEqual(cleanup["action"] as? String, "archive")
        XCTAssertTrue(task.contains("modify_matching with action archive"))
    }

    func testOnlyActionableGmailCategoriesProduceCleanup() {
        XCTAssertEqual(
            GmailMailCategory.from(labels: ["INBOX", "CATEGORY_PROMOTIONS"]),
            .promotions)
        XCTAssertEqual(
            GmailMailCategory.from(labels: ["INBOX", "CATEGORY_PURCHASES"]),
            .purchases)
        XCTAssertEqual(
            GmailMailCategory.from(labels: ["INBOX", "CATEGORY_RESERVATIONS"]),
            .reservations)

        let item = EmailCleanupInput(
            account: "owner@example.test", id: "message-44",
            from: "updates@shop.example")
        let ordinary = EmailCleanupDecision(
            category: .updates, action: .archive,
            senderInboxCount: 4, atLeast: false)
        XCTAssertNil(EmailCleanupPolicy.cleanupPayload(item: item, decision: ordinary))
    }

    func testCleanupRejectsInvalidSenderAndEmptyCount() {
        let invalid = EmailCleanupInput(
            account: "owner@example.test", id: "message-45", from: "Shop")
        let valid = EmailCleanupInput(
            account: "owner@example.test", id: "message-46", from: "sale@shop.example")
        let decision = EmailCleanupDecision(
            category: .promotions, action: .archive,
            senderInboxCount: 37, atLeast: false)
        let empty = EmailCleanupDecision(
            category: .promotions, action: .archive,
            senderInboxCount: 0, atLeast: false)

        XCTAssertNil(EmailCleanupPolicy.cleanupPayload(item: invalid, decision: decision))
        XCTAssertNil(EmailCleanupPolicy.cleanupPayload(item: valid, decision: empty))
    }
}
