import AppIntents
import XCTest
@testable import CodenameJo

final class ShortcutSenderIdentityTests: XCTestCase {
    func testSameNameDoesNotAuthorizeAnotherNumber() {
        let expected = IntentPerson(identifier: .contact("taylor"), name: .displayName("Taylor"),
                                    handle: .init(phoneNumber: "+12025550123"))
        let unrelated = IntentPerson(identifier: .contact("other"), name: .displayName("Taylor"),
                                     handle: .init(phoneNumber: "+12025550124"))
        XCTAssertFalse(ShortcutSenderIdentity.matches(unrelated, expected: expected))
    }

    func testReadAcceptsContactIDAndNumberAliases() {
        let expected = IntentPerson(identifier: .contact("taylor"), name: .displayName("Taylor"),
                                    handle: .init(phoneNumber: "+12025550123"),
                                    aliases: [.init(phoneNumber: "+12025550124")])
        let contact = IntentPerson(identifier: .contact("taylor"), name: .unknown, handle: nil)
        let alias = IntentPerson(handle: .init(phoneNumber: "+1 (202) 555-0124"))
        XCTAssertTrue(ShortcutSenderIdentity.matches(contact, expected: expected))
        XCTAssertTrue(ShortcutSenderIdentity.matches(alias, expected: expected))
        XCTAssertFalse(ShortcutSenderIdentity.matches(
            IntentPerson(handle: .init(phoneNumber: "2025550124")), expected: expected))
    }
}
