// coverage-target: Shared/VoiceActivityAttributes.swift

import XCTest

@testable import CodenameJo

/// The Lock Screen's whole vocabulary: the string cap that pays for ActivityKit's 4 KB
/// budget, the one-word status the surface leads with, and the button that must name the
/// action rather than the state it is already in.
///
/// None of this is reachable from the app's own screens, so a wrong answer here shows up
/// only on a Lock Screen during a live call — which is the one place nobody is looking
/// when it breaks.
final class LiveActivityContentStateTests: XCTestCase {

    // MARK: - Card.short

    func testAStringExactlyAtTheLimitIsLeftAlone() {
        // The boundary is `>`, so a string of exactly `limit` characters is not truncated
        // and keeps every character — an off-by-one here would cut a name that fitted.
        XCTAssertEqual(VoiceActivityAttributes.Card.short("abcde", 5), "abcde")
        XCTAssertEqual(VoiceActivityAttributes.Card.short("abcd", 5), "abcd")
    }

    func testAnOverlongStringIsCutToTheLimitWithTheEllipsisCounted() {
        let cut = VoiceActivityAttributes.Card.short("abcdefghij", 5)

        // The ellipsis is inside the budget, not added on top of it: four characters plus
        // one "…" is five, which is what the 4 KB cap is being paid with.
        XCTAssertEqual(cut, "abcd\u{2026}")
        XCTAssertEqual(cut.count, 5)
    }

    func testTheCutTrimsATrailingSpaceBeforeTheEllipsis() {
        // "abcd efgh" cut at 6 prefixes "abcd " — the trailing space is dropped, so the
        // result is shorter than the limit rather than reading as "abcd …".
        let cut = VoiceActivityAttributes.Card.short("abcd efgh", 6)

        XCTAssertEqual(cut, "abcd\u{2026}")
        XCTAssertFalse(cut.contains(" \u{2026}"))
    }

    func testSurroundingWhitespaceIsTrimmedBeforeTheLengthIsMeasured() {
        // A padded short string must not be truncated for whitespace it does not draw.
        XCTAssertEqual(VoiceActivityAttributes.Card.short("   Sarah Chen \n", 12), "Sarah Chen")
    }

    // MARK: - statusLabel

    func testMutedOutranksEveryPhase() {
        // The mute flag is the thing that changes what the user should do, so it wins over
        // a call that is still speaking — a muted call showing "Speaking" is how someone
        // ends up talking into a closed microphone.
        for phase in [VoiceActivityAttributes.Phase.connecting, .listening, .thinking, .speaking] {
            let state = VoiceActivityAttributes.ContentState(
                phase: phase, isMuted: true, detail: "Searching Gmail", card: nil)
            XCTAssertEqual(state.statusLabel, "Muted", "\(phase) muted")
        }
    }

    func testOnlyThinkingBorrowsTheToolDetailAndItFallsBackWhenThereIsNone() {
        let running = VoiceActivityAttributes.ContentState(
            phase: .thinking, isMuted: false, detail: "Searching Gmail", card: nil)
        XCTAssertEqual(running.statusLabel, "Searching Gmail")

        let bare = VoiceActivityAttributes.ContentState(
            phase: .thinking, isMuted: false, detail: nil, card: nil)
        XCTAssertEqual(bare.statusLabel, "Thinking")

        // The other three phases name themselves and ignore a detail that is still set —
        // a tool name under "Speaking" would be reporting the step already finished.
        let speaking = VoiceActivityAttributes.ContentState(
            phase: .speaking, isMuted: false, detail: "Searching Gmail", card: nil)
        XCTAssertEqual(speaking.statusLabel, "Speaking")

        let connecting = VoiceActivityAttributes.ContentState(
            phase: .connecting, isMuted: false, detail: "Searching Gmail", card: nil)
        XCTAssertEqual(connecting.statusLabel, "Connecting")

        let listening = VoiceActivityAttributes.ContentState(
            phase: .listening, isMuted: false, detail: "Searching Gmail", card: nil)
        XCTAssertEqual(listening.statusLabel, "Listening")
    }

    func testTheMuteButtonNamesTheActionRatherThanTheState() {
        let open = VoiceActivityAttributes.ContentState(
            phase: .listening, isMuted: false, detail: nil, card: nil)
        XCTAssertEqual(open.muteLabel, "Mute")
        XCTAssertEqual(open.muteSymbol, "mic.fill")

        let muted = VoiceActivityAttributes.ContentState(
            phase: .listening, isMuted: true, detail: nil, card: nil)
        XCTAssertEqual(muted.muteLabel, "Unmute")
        XCTAssertEqual(muted.muteSymbol, "mic.slash.fill")
    }

    // MARK: - Crossing into the widget

    func testTheStateSurvivesTheRoundTripIntoTheWidgetExtension() throws {
        // This type is the only thing that crosses into the extension, and it crosses as
        // encoded bytes. A card that does not decode draws nothing at all.
        let sent = VoiceActivityAttributes.ContentState(
            phase: .thinking, isMuted: false, detail: "Reading mail",
            card: .triage(position: 3, total: 51))

        let back = try JSONDecoder().decode(
            VoiceActivityAttributes.ContentState.self,
            from: try JSONEncoder().encode(sent))

        XCTAssertEqual(back, sent)
        guard case .triage(let position, let total) = try XCTUnwrap(back.card) else {
            return XCTFail("the card did not decode as a triage card")
        }
        XCTAssertEqual(position, 3)
        XCTAssertEqual(total, 51)
        XCTAssertEqual(back.statusLabel, "Reading mail")
    }
}
