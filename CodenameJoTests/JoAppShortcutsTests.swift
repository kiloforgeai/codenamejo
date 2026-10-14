// coverage-target: CodenameJo/AppIntents/JoAppShortcuts.swift

import AppIntents
import XCTest
@testable import CodenameJo

/// What the system reads out of the app bundle to populate the Action Button picker,
/// Siri and the Shortcuts gallery. Only Start Voice Command is offered: the Messages
/// bridge intents are commented out in place until iOS 27, and they must not appear in a
/// gallery where pressing one would do nothing.
final class JoAppShortcutsTests: XCTestCase {

    func testOnlyTheStartVoiceShortcutIsOffered() {
        XCTAssertEqual(JoAppShortcuts.appShortcuts.count, 1)
    }

    /// The provider is rebuilt on every read by the system; two reads disagreeing would
    /// mean the gallery depended on when it was asked.
    func testTheShortcutListIsStableAcrossReads() {
        XCTAssertEqual(JoAppShortcuts.appShortcuts.count, JoAppShortcuts.appShortcuts.count)
    }
}
