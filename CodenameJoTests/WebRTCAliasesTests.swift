// coverage-target: CodenameJo/Services/FullDuplex/WebRTCAliases.swift

import XCTest

@testable import CodenameJo

/// The one seam between this app's transport code and LiveKit's libwebrtc build.
///
/// The file is almost entirely `typealias`, which the compiler checks for us. One line is
/// not: `RTCInitializeSSL()` forwards to the prefixed `LKRTCInitializeSSL`, and the
/// transport's one-time setup believes its answer. If a binary swap ever left that forward
/// pointing at something that reports failure — or if initialising twice in one process were
/// to start answering `false` — a dial would refuse with nothing in the log to say why, and
/// no compile error anywhere.
final class WebRTCAliasesTests: XCTestCase {

    /// The forward resolves and libwebrtc's SSL stack comes up.
    func testTheAliasedSslInitialiserReportsSuccess() {
        XCTAssertTrue(RTCInitializeSSL(), "libwebrtc refused to initialise SSL")
    }

    /// The call is not guarded by a `dispatch_once` on our side — the transport runs it on
    /// setup and a test host may already have — so a second call in the same process has to
    /// report success as well, or a re-dial would read as a broken SSL stack.
    func testInitialisingTwiceInOneProcessStillReportsSuccess() {
        XCTAssertTrue(RTCInitializeSSL())
        XCTAssertTrue(RTCInitializeSSL(), "a second initialise must not read as a failure")
    }
}
