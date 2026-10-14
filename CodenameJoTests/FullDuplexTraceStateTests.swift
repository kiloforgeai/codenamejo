// coverage-target: CodenameJo/Services/FullDuplex/FullDuplexTrace.swift

import XCTest

@testable import CodenameJo

/// Data-channel tracing prints a line per frame over a session that produces hundreds, so
/// the only thing standing between a shipped build and that firehose is this switch. What
/// matters is when it is read — once per session, at `begin()` — and that signing out
/// really forgets it.
final class FullDuplexTraceStateTests: XCTestCase {

    private var saved: Any?

    override func setUpWithError() throws {
        saved = UserDefaults.standard.object(forKey: FullDuplexTrace.storageKey)
        UserDefaults.standard.removeObject(forKey: FullDuplexTrace.storageKey)
        // The enabled flag is process-wide; start every case from a known-off session.
        FullDuplexTrace.clearLocal()
    }

    override func tearDownWithError() throws {
        FullDuplexTrace.clearLocal()
        if let saved {
            UserDefaults.standard.set(saved, forKey: FullDuplexTrace.storageKey)
        } else {
            UserDefaults.standard.removeObject(forKey: FullDuplexTrace.storageKey)
        }
        saved = nil
    }

    func testAnAbsentKeyLeavesTracingOff() {
        // Off by default is the whole point: the launch argument is the only way in, and a
        // missing key must not read as "on" on a device nobody is debugging.
        XCTAssertNil(UserDefaults.standard.object(forKey: FullDuplexTrace.storageKey))

        FullDuplexTrace.begin()

        XCTAssertFalse(FullDuplexTrace.isOn)
    }

    func testTheLaunchArgumentTurnsTracingOnAtTheStartOfASession() {
        UserDefaults.standard.set(true, forKey: FullDuplexTrace.storageKey)

        FullDuplexTrace.begin()

        XCTAssertTrue(FullDuplexTrace.isOn)
    }

    func testTheSwitchIsReadOncePerSessionAndNotPerFrame() {
        UserDefaults.standard.set(true, forKey: FullDuplexTrace.storageKey)
        FullDuplexTrace.begin()
        XCTAssertTrue(FullDuplexTrace.isOn)

        // Flipping the stored key mid-call must not change what this session is doing:
        // the value is cached deliberately, because a `UserDefaults` hit per frame is not
        // free on the data-channel path.
        UserDefaults.standard.set(false, forKey: FullDuplexTrace.storageKey)
        XCTAssertTrue(FullDuplexTrace.isOn)

        // …and the next session picks the new answer up.
        FullDuplexTrace.begin()
        XCTAssertFalse(FullDuplexTrace.isOn)
    }

    func testSigningOutForgetsTracingRatherThanJustStoppingIt() {
        UserDefaults.standard.set(true, forKey: FullDuplexTrace.storageKey)
        FullDuplexTrace.begin()
        XCTAssertTrue(FullDuplexTrace.isOn)

        FullDuplexTrace.clearLocal()

        // Both halves matter. The live flag goes off immediately, and the key is removed
        // rather than set false — so the next sign-in starts from a fresh install's
        // answer instead of inheriting the last user's debugging.
        XCTAssertFalse(FullDuplexTrace.isOn)
        XCTAssertNil(UserDefaults.standard.object(forKey: FullDuplexTrace.storageKey))

        FullDuplexTrace.begin()
        XCTAssertFalse(FullDuplexTrace.isOn)
    }
}
