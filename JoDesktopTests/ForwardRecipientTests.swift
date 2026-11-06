import XCTest
@testable import CodenameJo

final class ForwardRecipientTests: XCTestCase {
    private var source: MailMIME.ForwardSource {
        .init(from: "Vendor Person <notifications@billing.example>", replyTo: "Vendor Person <vendor@example.test>",
              text: "Contact Vendor Person at vendor@example.test.")
    }

    func testNotificationDisplayNameCannotAuthorizeSenderAddress() throws {
        for request in [nil, "Forward this to Vendor Person whose address is here.",
                        "Do not forward to notifications@billing.example; use the human address."] {
            XCTAssertThrowsError(try ForwardRecipient.resolve("notifications@billing.example", source: source, userRequest: request))
        }
        let resolved = try ForwardRecipient.resolve("vendor@example.test", source: source, userRequest: nil)
        XCTAssertEqual(resolved.basis, "source_reply_to")
        XCTAssertEqual(resolved.sender, source.from)
    }

    func testExplicitOverrideAndUnrelatedRecipientAreNotRewritten() throws {
        let explicit = try ForwardRecipient.resolve("notifications@billing.example", source: source,
            userRequest: "Forward this to notifications@billing.example.")
        XCTAssertEqual(explicit.basis, "explicit_user_address")
        XCTAssertEqual(explicit.address, "notifications@billing.example")
        let other = try ForwardRecipient.resolve("other@example.test", source: source, userRequest: nil)
        XCTAssertEqual(other.address, "other@example.test")
        XCTAssertEqual(other.basis, "selected_destination")
    }

    func testMissingReplyToAndConflictingContactsRequireResolution() throws {
        var missing = source
        missing.replyTo = ""
        XCTAssertThrowsError(try ForwardRecipient.resolve("notifications@billing.example", source: missing, userRequest: nil))
        var conflict = source
        conflict.replyTo = "Vendor <vendor@example.test>, Other <other@example.test>"
        XCTAssertThrowsError(try ForwardRecipient.resolve("vendor@example.test", source: conflict, userRequest: nil))
        let human = MailMIME.ForwardSource(from: "Vendor <vendor@example.test>")
        XCTAssertNoThrow(try ForwardRecipient.resolve("vendor@example.test", source: human, userRequest: nil))
    }
}
