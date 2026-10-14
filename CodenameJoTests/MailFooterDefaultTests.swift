// coverage-target: CodenameJo/Models/MailFooter.swift

import XCTest

@testable import CodenameJo

/// Whether mail the assistant sends carries our branding under it.
///
/// The footer is on somebody else's message to a person they know, so the default is the
/// whole point of this type: it went out on by default once and came back off the next
/// day. Nothing on the phone reads it — the broker does, off the mirrored profile field —
/// and the broker reads a missing field as off too. Both ends therefore have to treat an
/// absent key as off without either trusting the other to have been updated, which is the
/// contract these assertions hold.
///
/// These write the real `UserDefaults` the production code reads, so whatever this device
/// already had is put back afterwards.
final class MailFooterDefaultTests: XCTestCase {

    private var saved: Any?

    override func setUp() {
        super.setUp()
        saved = UserDefaults.standard.object(forKey: MailFooter.storageKey)
        UserDefaults.standard.removeObject(forKey: MailFooter.storageKey)
    }

    override func tearDown() {
        if let saved {
            UserDefaults.standard.set(saved, forKey: MailFooter.storageKey)
        } else {
            UserDefaults.standard.removeObject(forKey: MailFooter.storageKey)
        }
        saved = nil
        super.tearDown()
    }

    /// An account that has never answered must not get the footer. This is the one that
    /// regressed before, and it is the reason the key is read through `object(forKey:)`
    /// rather than a default the toggle could be flipped on by.
    func testAnUnansweredAccountDoesNotGetTheFooter() {
        XCTAssertNil(UserDefaults.standard.object(forKey: MailFooter.storageKey))
        XCTAssertFalse(MailFooter.isOn)
    }

    func testTurningItOnReadsAsOn() {
        UserDefaults.standard.set(true, forKey: MailFooter.storageKey)
        XCTAssertTrue(MailFooter.isOn)
    }

    func testTurningItOffAgainReadsAsOff() {
        UserDefaults.standard.set(true, forKey: MailFooter.storageKey)
        XCTAssertTrue(MailFooter.isOn)

        UserDefaults.standard.set(false, forKey: MailFooter.storageKey)
        XCTAssertFalse(MailFooter.isOn)
    }

    /// A value of the wrong shape is somebody else's write, not an answer. It falls back
    /// to off rather than being coerced — the branding goes out only on a stored `true`.
    func testAValueThatIsNotABooleanFallsBackToOff() {
        UserDefaults.standard.set("true", forKey: MailFooter.storageKey)
        XCTAssertFalse(MailFooter.isOn,
                       "Only a stored boolean true turns the footer on")
    }

    /// `mailFooterEnabled` is the field the broker reads off the profile row; the local
    /// key has to spell it the same way or the toggle writes somewhere nothing reads.
    func testTheKeyIsTheFieldTheBrokerReads() {
        XCTAssertEqual(MailFooter.storageKey, "mailFooterEnabled")
    }
}
