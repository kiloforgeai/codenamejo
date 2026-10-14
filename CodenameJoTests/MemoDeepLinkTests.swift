// coverage-target: Shared/StartMemoIntent.swift

import XCTest
@testable import CodenameJo

/// The Home Screen widget reaches the memo recorder through a URL rather than through
/// `perform()`, because a widget button runs in the extension's process. `MemoDeepLink`
/// is the only thing standing between that URL and an open microphone, and the app
/// already registers `aurex://` for the Gmail-connect callback — so the host is what
/// separates a memo request from an OAuth return.
@MainActor
final class MemoDeepLinkTests: XCTestCase {

    override func tearDown() async throws {
        VoiceSessionLauncher.shared.consumeMemo()
        VoiceSessionLauncher.shared.consume()
        try await super.tearDown()
    }

    func testDeepLinkURLCarriesTheAurexSchemeAndMemoHost() {
        XCTAssertEqual(MemoDeepLink.url.scheme, "aurex")
        XCTAssertEqual(MemoDeepLink.url.host, "memo")
    }

    func testTheDeepLinkURLMatchesItself() {
        XCTAssertTrue(MemoDeepLink.matches(MemoDeepLink.url))
    }

    func testTheSessionHostIsNotAMemoRequest() {
        let url = try! XCTUnwrap(URL(string: "aurex://session"))
        XCTAssertFalse(MemoDeepLink.matches(url))
    }

    /// The OAuth return the app already registers the scheme for. Treating it as a memo
    /// would open the microphone at the end of connecting a mailbox.
    func testTheGmailConnectedCallbackIsNotAMemoRequest() {
        let url = try! XCTUnwrap(URL(string: "aurex://gmail-connected?code=abc"))
        XCTAssertFalse(MemoDeepLink.matches(url))
    }

    /// The host alone is not enough: any web page could carry `//memo`.
    func testAnHTTPSURLWithAMemoHostIsRejected() {
        let url = try! XCTUnwrap(URL(string: "https://memo"))
        XCTAssertFalse(MemoDeepLink.matches(url))
    }

    /// A widget URL may gain a path without changing what it asks for.
    func testAMemoHostStillMatchesWithATrailingPath() {
        let url = try! XCTUnwrap(URL(string: "aurex://memo/start"))
        XCTAssertTrue(MemoDeepLink.matches(url))
    }

    /// `aurex:memo` is an opaque URL with no host at all, so it must not match.
    func testASchemeWithoutAHostIsRejected() {
        let url = try! XCTUnwrap(URL(string: "aurex:memo"))
        XCTAssertNil(url.host)
        XCTAssertFalse(MemoDeepLink.matches(url))
    }

    /// The intent's whole job: raise the memo flag and nothing else. A memo must never
    /// place a call, which is why the launcher keeps the two requests on separate flags.
    func testTheIntentRequestsAMemoWithoutRequestingACall() async throws {
        let launcher = VoiceSessionLauncher.shared
        launcher.consumeMemo()
        launcher.consume()
        XCTAssertFalse(launcher.pendingMemo)

        _ = try await StartMemoIntent().perform()

        XCTAssertTrue(launcher.pendingMemo)
        XCTAssertFalse(launcher.pendingLaunch)
    }
}
