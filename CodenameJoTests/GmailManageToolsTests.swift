import XCTest
@testable import CodenameJo

/// The phone's mail-management tools: what is declared, and the pure halves of running them.
final class GmailManageToolsTests: XCTestCase {
    func testFilterWritesAreOfferedOnlyWhereTheScopeWasGranted() {
        let names = { (filters: [String]) in
            Set(GmailManageTools.definitions(accounts: ["owner@example.test"], filterAccounts: filters)
                .compactMap { $0["name"] as? String })
        }
        XCTAssertEqual(names(["owner@example.test"]), GmailManageTools.names)
        XCTAssertEqual(names([]), GmailManageTools.names.subtracting(["gmail_create_mailbox_filter", "gmail_delete_mailbox_filter"]))
        XCTAssertTrue(GmailManageTools.definitions(accounts: [], filterAccounts: []).isEmpty)
    }

    func testAQueueFillsTheMessageAndTheSenderButNeverAnUnarchive() throws {
        let step = #"{"done":false,"item":{"id":"m1","account":"owner@example.test","threadId":"t1","from":"Shop <news@shop.example>"}}"#
        let cursor = try XCTUnwrap(GmailManageTools.cursor(step: step))
        XCTAssertEqual(cursor.senders, ["news@shop.example"])
        func filled(_ name: String, _ args: String) -> [String: Any] {
            let json = GmailManageTools.resolvedArguments(name: name, argumentsJSON: args, cursor: cursor)
            return (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
        }
        XCTAssertEqual(filled("gmail_unsubscribe_sender", "{}")["message_id"] as? String, "m1")
        XCTAssertNil(filled("gmail_unsubscribe_sender", #"{"sender":"other.example"}"#)["message_id"])
        XCTAssertNil(filled("gmail_unarchive_message", "{}")["message_id"])
        XCTAssertEqual(filled("gmail_modify_matching", #"{"action":"archive"}"#)["query"] as? String, "from:news@shop.example")
        XCTAssertNil(filled("gmail_modify_matching", #"{"action":"unlabel","label":"X"}"#)["query"])
    }

    func testASweepMustNameWhatItMatches() {
        XCTAssertNotNil(GmailManageTools.sweepRefusal("in:inbox is:unread -from:me", kind: .archive))
        XCTAssertNil(GmailManageTools.sweepRefusal("from:hi@easyplant.com", kind: .archive))
        XCTAssertEqual(GmailManageTools.refuseAbove(.spam), 1_000)
        XCTAssertTrue(GmailManageTools.sweepTooBig(count: 0, atLeast: true, kind: .spam).contains("more than 1000"))
    }

    func testSystemLabelsAreRefusedByName() {
        XCTAssertTrue(GmailManageTools.systemLabelRefusal(" spam ")?.hasPrefix("Spam is not a label.") == true)
        XCTAssertTrue(GmailManageTools.systemLabelRefusal("Inbox")?.contains("unarchive_message") == true)
        XCTAssertNil(GmailManageTools.systemLabelRefusal("Receipts"))
    }

    func testOneClickNeedsBothHeadersAndASignature() {
        let headers = GmailManageTools.parseUnsubscribe(
            "<mailto:leave@list.example?subject=stop>, <https://list.example/u/1>",
            post: "List-Unsubscribe=One-Click", authentication: "mx; dkim=pass header.d=list.example")
        XCTAssertEqual(headers.oneClick, "https://list.example/u/1")
        XCTAssertNil(headers.link)
        XCTAssertEqual(headers.mailto?.subject, "stop")
        XCTAssertTrue(headers.dkimPass)
        XCTAssertEqual(GmailManageTools.parseUnsubscribe("<https://list.example/u/1>", post: "",
                                                         authentication: "dkim=passthrough").link, "https://list.example/u/1")
        XCTAssertFalse(GmailManageTools.parseUnsubscribe("", post: "", authentication: "dkim=passthrough").dkimPass)
    }

    func testAnUnsubscribeURLMustBeAPublicHTTPSHost() {
        XCTAssertNotNil(GmailManageTools.safeUnsubscribeURL("https://list.example/u/1"))
        XCTAssertNil(GmailManageTools.safeUnsubscribeURL("http://list.example/u/1"))
        XCTAssertNil(GmailManageTools.safeUnsubscribeURL("https://192.168.1.1/u"))
        XCTAssertNil(GmailManageTools.safeUnsubscribeURL("https://printer.local/u"))
        XCTAssertNil(GmailManageTools.safeUnsubscribeURL("https://user:pw@list.example/u"))
    }

    func testAFilterIsReadBackInPlainWords() {
        let filter: [String: Any] = ["id": "f1", "criteria": ["from": "stripe.com"],
                                     "action": ["addLabelIds": ["Label_7"], "removeLabelIds": ["INBOX"]]]
        let described = GmailManageTools.describeFilter(filter) { $0 == "Label_7" ? "Receipts" : $0 }
        XCTAssertEqual(described.matches, "from stripe.com")
        XCTAssertEqual(described.does, "labelled \"Receipts\" and kept out of the inbox")
        XCTAssertTrue(GmailManageTools.isRebuildable(filter))
        XCTAssertFalse(GmailManageTools.isRebuildable(["action": ["forward": "a@example.test"]]))
    }
}
