import XCTest
@testable import CodenameJo

/// What a failed dial is allowed to put under the orb.
///
/// The regression this guards is on the screen, not in the log: a handshake failure once
/// printed `OpenAI SDP handshake 401: {` truncated mid-JSON where a sentence belonged. The
/// mapping is substring matching over text from four layers, so the order of the clauses is
/// the behaviour — a message that matches two of them takes the first, and which one that is
/// decides whether the user is told to retry or to go and check their connections.
final class VoiceFailureTextTests: XCTestCase {

    // MARK: - Each class of failure

    func testEveryConnectionFailureReadsAsOneSentenceAboutTheNetwork() {
        let offline = "No connection — tap to try again"
        XCTAssertEqual(
            VoiceFailureText.friendly("The Internet connection appears to be offline."), offline)
        XCTAssertEqual(
            VoiceFailureText.friendly("The network connection was lost."), offline)
        XCTAssertEqual(VoiceFailureText.friendly("The request timed out."), offline)
    }

    func testARefusalForRateIsDistinguishedFromARefusalForPermission() {
        XCTAssertEqual(
            VoiceFailureText.friendly("429 rate_limit_exceeded"),
            "Busy right now — try again in a moment")
        XCTAssertEqual(
            VoiceFailureText.friendly("403 Forbidden"),
            "This account can't start a call — check your connections")
    }

    /// The literal string that shipped onto the main screen.
    func testTheHandshakeFailureThatShippedOnScreenIsNowASentence() {
        let raw = "OpenAI SDP handshake 401: {\"error\":{\"message\":\"Invalid"
        let friendly = VoiceFailureText.friendly(raw)

        XCTAssertEqual(friendly, "Couldn't start the call — tap to try again")
        XCTAssertFalse(friendly.contains("{"), "no JSON reaches the screen")
        XCTAssertFalse(friendly.contains("401"), "and no status code either")
    }

    func testAMicrophoneRefusalSendsTheUserSomewhereTheyCanFixIt() {
        XCTAssertEqual(
            VoiceFailureText.friendly("Microphone permission denied"),
            "Microphone access is off — turn it on in Settings")
    }

    func testAnUnrecognisedFailureStillGetsAnActionableSentence() {
        let friendly = VoiceFailureText.friendly("EOF on data channel")
        XCTAssertEqual(friendly, "Something went wrong — tap to try again")
    }

    func testAnEmptyErrorIsNotAnEmptyScreen() {
        XCTAssertFalse(VoiceFailureText.friendly("").isEmpty)
    }

    // MARK: - Matching is case-blind, and the order of the clauses matters

    func testMatchingIgnoresTheCaseTheLayerBelowHappenedToUse() {
        XCTAssertEqual(
            VoiceFailureText.friendly("UNAUTHORIZED"),
            VoiceFailureText.friendly("unauthorized"))
        XCTAssertEqual(
            VoiceFailureText.friendly("Rate Limit Exceeded"),
            VoiceFailureText.friendly("rate limit exceeded"))
    }

    /// A token mint that timed out is a connection failure, not a credential one — so the
    /// network clause has to be read before the one that matches the word "token".
    func testATimedOutTokenMintIsReportedAsAConnectionFailure() {
        XCTAssertEqual(
            VoiceFailureText.friendly("Bearer token request timed out"),
            "No connection — tap to try again")
    }
}
