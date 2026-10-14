import XCTest
@testable import CodenameJo

final class LocalVoicePickTests: XCTestCase {
    private func voice(_ name: String, _ quality: Int, language: String = "en-US") -> LocalVoiceCandidate {
        LocalVoiceCandidate(identifier: "com.apple.voice.\(quality).\(language).\(name)", name: name,
                            language: language, quality: quality)
    }

    func testTheBestEnglishVoiceWins() {
        let installed = [voice("Samantha", 1), voice("Zoe", 3), voice("Ava", 3), voice("Evan", 2),
                         voice("Kate", 3, language: "en-GB")]
        XCTAssertEqual(LocalVoiceSettings.pick(from: installed)?.name, "Ava")
    }

    func testNoEnglishVoiceMeansTheSynthesizerDefault() {
        XCTAssertNil(LocalVoiceSettings.pick(from: [voice("Anna", 3, language: "de-DE")]))
        XCTAssertNil(LocalVoiceSettings.pick(from: []))
    }

    func testAnUnknownStoredChoiceIsKokoro() {
        UserDefaults.standard.set("zoe", forKey: LocalVoice.storageKey)
        defer { UserDefaults.standard.removeObject(forKey: LocalVoice.storageKey) }
        XCTAssertEqual(LocalVoice.current, .paradee)
    }
}
