import XCTest
@testable import CodenameJo

final class ShortcutReadPolicyTests: XCTestCase {
    func testOnlyAllUnreadRequestsAreAccepted() {
        for arguments in ["{}", #"{"about":""}"#, #"{"about":" \n "}"#,
                          #"{"unread":true}"#, #"{"about":"","unread":true}"#] {
            XCTAssertNil(ShortcutReadPolicy.refusal(for: arguments), arguments)
        }
    }

    func testContactRequestsNeverWidenToEveryonesUnreadTexts() throws {
        for about in ["Raghav Kiloforge", "+12025550123", "sender@example.test"] {
            for unread in [true, false] {
                let data = try JSONSerialization.data(withJSONObject: ["about": about, "unread": unread])
                let refusal = try XCTUnwrap(ShortcutReadPolicy.refusal(for: String(decoding: data, as: UTF8.self)))
                XCTAssertTrue(refusal.contains("specific contact"))
                XCTAssertTrue(refusal.contains("No messages were read"))
            }
        }
    }

    func testExplicitAlreadyReadRequestIsNotReinterpretedAsUnread() throws {
        let refusal = try XCTUnwrap(ShortcutReadPolicy.refusal(for: #"{"about":"","unread":false}"#))
        XCTAssertTrue(refusal.contains("already-read"))
        XCTAssertTrue(refusal.contains("No messages were read"))
    }

    func testMalformedScopeNeverDefaultsToAllUnread() {
        for arguments in ["", "[]", "not json", #"{"about":123}"#,
                          #"{"about":["Raghav"]}"#, #"{"unread":"false"}"#,
                          #"{"unread":0}"#] {
            XCTAssertNotNil(ShortcutReadPolicy.refusal(for: arguments), arguments)
        }
    }
}
