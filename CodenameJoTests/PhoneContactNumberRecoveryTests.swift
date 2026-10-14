import AppIntents
import XCTest
@testable import CodenameJo

@available(iOS 27, *)
@MainActor
final class PhoneContactNumberRecoveryTests: XCTestCase {
    func testExactNumberDoesNotQueryContacts() async throws {
        let contacts = UnavailableContacts()
        let person = try await contacts.person(for: "+1 202 555 0123")
        XCTAssertFalse(contacts.queried)
        guard case .phoneNumber(let number) = person?.handle?.value else {
            return XCTFail("Expected an exact-number person")
        }
        XCTAssertEqual(number, "+1 202 555 0123")
    }

    func testReadPreservesMultiNumberContactAndSendRequiresDisambiguation() async throws {
        let contacts = MultiNumberContacts()
        let resolved = try await contacts.person(for: "Example Person")
        let person = try XCTUnwrap(resolved)
        guard case .contact(let identifier) = person.identifier else {
            return XCTFail("A named read should retain the contact identity")
        }
        XCTAssertEqual(identifier, "fixture-contact")
        XCTAssertEqual(person.aliases.count, 1)
        do {
            _ = try await contacts.handle(for: "Example Person")
            XCTFail("Sending must still require one exact number")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("which one"))
        }
    }

    func testContactReadAcceptsAnEmailOnlyMessageSender() async throws {
        let resolved = try await EmailContacts().person(for: "Example Person")
        let expected = try XCTUnwrap(resolved)
        XCTAssertTrue(ShortcutSenderIdentity.matches(
            IntentPerson(handle: .init(emailAddress: "person@example.com")), expected: expected))
        XCTAssertFalse(ShortcutSenderIdentity.matches(
            IntentPerson(handle: .init(emailAddress: "other@example.com")), expected: expected))
    }

    func testLimitedNameLookupCannotClaimAUniqueContact() async {
        let contacts = LimitedContacts()
        guard case .limited = await contacts.search("Example Person") else {
            return XCTFail("A partial contact list cannot prove that a name is unique")
        }
        do {
            _ = try await contacts.handle(for: "Example Person")
            XCTFail("Limited name lookup must not select a send recipient")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("full Contacts access"))
            XCTAssertTrue(error.localizedDescription.contains("exact phone number"))
        }
    }

    func testLimitedPermissionStillAllowsAnExactSendNumber() async throws {
        let number = try await LimitedContacts().handle(for: "+12025550123")
        XCTAssertEqual(number, "+12025550123")
    }

    func testDuplicateNamesNeedClarificationEvenWhenOnlyOneHasAPhone() async {
        let contacts = AmbiguousContacts()
        let outcome = await contacts.search("Example Person")
        let output = contacts.modelOutput(for: outcome, query: "Example Person")
        XCTAssertTrue(output.contains("Ask the user which one"))
        XCTAssertFalse(output.contains("Use this number as the recipient"))
        do {
            _ = try await contacts.handle(for: "Example Person")
            XCTFail("One reachable contact is not one matching person")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Ask the user which one"))
        }
    }

    func testOneFullyResolvedContactWithOnePhoneStillProvidesTheRecipient() {
        let match = PhoneContacts.Match(identifier: "single", name: "Example Person", organization: "",
                                        phones: [("mobile", "+12025550123")])
        let output = PhoneContacts().modelOutput(for: .matches([match]), query: "Example Person")
        XCTAssertTrue(output.contains("Use this number as the recipient"))
        XCTAssertTrue(output.contains("+12025550123"))
    }

    func testNameStillSurfacesDeniedPermission() async {
        let contacts = UnavailableContacts()
        do {
            _ = try await contacts.person(for: "Example Person")
            XCTFail("A name requires contact resolution")
        } catch {
            XCTAssertTrue(contacts.queried)
            XCTAssertTrue(error.localizedDescription.contains("permission"))
        }
    }
}

private class UnavailableContacts: PhoneContacts {
    var queried = false

    @MainActor
    override func search(_ name: String) async -> Outcome {
        queried = true
        return .denied
    }
}

private class MultiNumberContacts: PhoneContacts {
    @MainActor
    override func search(_ name: String) async -> Outcome {
        .matches([Match(identifier: "fixture-contact", name: "Example Person", organization: "",
                        phones: [("mobile", "+12025550123"), ("home", "+12025550124")])])
    }
}

private class EmailContacts: PhoneContacts {
    @MainActor
    override func search(_ name: String) async -> Outcome {
        .matches([Match(identifier: "email-contact", name: "Example Person", organization: "",
                        phones: [("mobile", "+12025550123")], emails: ["person@example.com"])])
    }
}

private class LimitedContacts: PhoneContacts {
    override var permission: Permission { .limited }
}

private class AmbiguousContacts: PhoneContacts {
    @MainActor
    override func search(_ name: String) async -> Outcome {
        .matches([
            Match(identifier: "one", name: "Example Person", organization: "First company",
                  phones: [("mobile", "+12025550123")]),
            Match(identifier: "two", name: "Example Person", organization: "Second company", phones: [])
        ])
    }
}
