import Security
import XCTest
@testable import CodenameJo

final class OpenAIKeyStorageTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        suite = "OpenAIKeyStorageTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
    }

    func testReplacementUpdatesExistingKeyWithoutDeletingIt() throws {
        let status = try OpenAIKeyService.storeVerifiedKey("test-new-key", defaults: defaults,
            update: { _, attributes in
                XCTAssertEqual((attributes as NSDictionary)[kSecValueData] as? Data, Data("test-new-key".utf8))
                return errSecSuccess
            }, add: { _ in XCTFail("An existing key must be updated in place"); return errSecDuplicateItem })
        XCTAssertEqual(status, .init(set: true, last4: "-key"))
        XCTAssertTrue(defaults.bool(forKey: OpenAIKeyService.savedHereKey))
    }

    func testNewKeyUsesDeviceOnlyStorage() throws {
        _ = try OpenAIKeyService.storeVerifiedKey("test-key", defaults: defaults,
            update: { _, _ in errSecItemNotFound }, add: { item in
                XCTAssertEqual((item as NSDictionary)[kSecAttrAccessible] as? String,
                               kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
                return errSecSuccess
            })
        XCTAssertTrue(defaults.bool(forKey: OpenAIKeyService.savedHereKey))
    }

    func testMissingSigningEntitlementIsNotReportedAsOpenAINetworkFailure() {
        XCTAssertThrowsError(try OpenAIKeyService.storeVerifiedKey("test-key", defaults: defaults,
            update: { _, _ in errSecItemNotFound }, add: { _ in errSecMissingEntitlement })) { error in
                guard case OpenAIKeyService.Failure.secureStorage(errSecMissingEntitlement) = error else {
                    return XCTFail("Expected the Keychain status, got \(error)")
                }
                XCTAssertTrue(error.localizedDescription.contains("properly signed"))
                XCTAssertFalse(error.localizedDescription.contains("Couldn't reach OpenAI"))
            }
        XCTAssertFalse(defaults.bool(forKey: OpenAIKeyService.savedHereKey))
    }

    func testFailedReplacementDoesNotFallBackToAddOrChangeInstallMarker() {
        defaults.set(true, forKey: OpenAIKeyService.savedHereKey)
        XCTAssertThrowsError(try OpenAIKeyService.storeVerifiedKey("test-key", defaults: defaults,
            update: { _, _ in errSecInteractionNotAllowed },
            add: { _ in XCTFail("Do not replace a key after an update fails"); return errSecSuccess }))
        XCTAssertTrue(defaults.bool(forKey: OpenAIKeyService.savedHereKey))
    }
}
