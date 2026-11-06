import XCTest
@testable import CodenameJo

@MainActor
final class SupervisedBrowserExperimentTests: XCTestCase {
    private func make(profile: @escaping () -> String? = { "qa" }) -> SupervisedBrowserExperiment {
        .init(context: .init(jobID: UUID(), profileID: "qa",
            origin: .init(account: "qa@example.test", messageID: "R", threadID: "thread-R",
                sender: "Fixture", subject: "Workshop"), request: "Inspect availability"), profile: profile)
    }
    private func open(_ browser: SupervisedBrowserExperiment,
                      _ fixture: SupervisedBrowserExperiment.Fixture = .event) async throws {
        await browser.start(fixture)
        for _ in 0..<500 where browser.phase == .loading { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotEqual(browser.phase, .loading)
        XCTAssertNotEqual(browser.phase, .failed, browser.message)
    }
    private func submissions(_ browser: SupervisedBrowserExperiment) async throws -> Int {
        let value = try await browser.webView.evaluateJavaScript("Number(document.body.dataset.submissions || 0)")
        return value as? Int ?? -1
    }

    func testStaticAndJavaScriptFindingsRequireExactApprovalAndReturnHostApprovalReceipt() async throws {
        let browser = make()
        defer { browser.stop() }
        try await open(browser)
        XCTAssertTrue(try XCTUnwrap(browser.snapshot).text.contains("Synthetic Jo workshop"))
        XCTAssertFalse(try XCTUnwrap(browser.snapshot).text.contains("Two places shown"))
        await browser.choose("details")
        XCTAssertTrue(try XCTUnwrap(browser.snapshot).text.contains("Two places shown"))
        XCTAssertTrue(browser.resultSummary.contains("No request was submitted"))
        await browser.choose("request")
        XCTAssertEqual(browser.phase, .approval)
        let before = try await submissions(browser)
        XCTAssertEqual(before, 0)
        let approval = try XCTUnwrap(browser.pendingApproval)
        await browser.approve(UUID())
        let wrong = try await submissions(browser)
        XCTAssertEqual(wrong, 0, "An unrelated approval cannot authorize this action")
        await browser.approve(approval.id)
        XCTAssertEqual(browser.phase, .submitted)
        XCTAssertTrue(browser.message.contains("No booking is confirmed"))
        await browser.approve(approval.id)
        await browser.choose("request")
        let after = try await submissions(browser)
        XCTAssertEqual(after, 1)
        XCTAssertEqual(browser.context.origin.messageID, "R")
        XCTAssertTrue(browser.trace.contains { $0.event == "receipt_verified" })
        browser.stop()
        XCTAssertEqual(browser.phase, .submitted, "Stopping cannot erase a verified receipt")
    }

    func testChangedPageAndAmbiguousButtonNeverSubmit() async throws {
        let changed = make()
        defer { changed.stop() }
        try await open(changed)
        await changed.choose("details")
        await changed.choose("request")
        let approval = try XCTUnwrap(changed.pendingApproval)
        _ = try await changed.webView.evaluateJavaScript("document.getElementById('request').innerText='Pay $500 instead'")
        await changed.approve(approval.id)
        let writes = try await submissions(changed)
        XCTAssertEqual(writes, 0)
        XCTAssertTrue(changed.trace.contains { $0.event == "changed_page_refused" })
        let ambiguous = make()
        defer { ambiguous.stop() }
        try await open(ambiguous, .ambiguous)
        await ambiguous.choose("details")
        await ambiguous.choose("request")
        XCTAssertNil(ambiguous.pendingApproval)
        let ambiguousWrites = try await submissions(ambiguous)
        XCTAssertEqual(ambiguousWrites, 0)
    }

    func testLoginProfileSwitchStopAndTimeoutRefuseActions() async throws {
        let login = make()
        defer { login.stop() }
        try await open(login, .login)
        XCTAssertEqual(login.phase, .takeover)
        await login.choose("details")
        XCTAssertNil(login.pendingApproval)
        var profile: String? = "qa"
        let browser = make { profile }
        defer { browser.stop() }
        try await open(browser)
        profile = "different"
        await browser.choose("details")
        XCTAssertEqual(browser.phase, .stopped)
        let writes = try await submissions(browser)
        XCTAssertEqual(writes, 0)
        let timed = make()
        defer { timed.stop() }
        try await open(timed)
        timed.expire()
        await timed.choose("details")
        XCTAssertEqual(timed.phase, .timedOut)
        XCTAssertEqual(timed.snapshot?.submissions, 0)
    }

    func testUntrustedInstructionsDoNotAuthorizeAndUnknownSubmissionIsNotRetried() async throws {
        let untrusted = make()
        defer { untrusted.stop() }
        try await open(untrusted, .untrusted)
        await untrusted.choose("details")
        await untrusted.choose("request")
        XCTAssertEqual(untrusted.phase, .approval)
        let writes = try await submissions(untrusted)
        XCTAssertEqual(writes, 0)
        let unknown = make()
        defer { unknown.stop() }
        try await open(unknown, .unknownReceipt)
        await unknown.choose("details")
        await unknown.choose("request")
        let approval = try XCTUnwrap(unknown.pendingApproval)
        await unknown.approve(approval.id)
        XCTAssertEqual(unknown.phase, .unknown)
        XCTAssertEqual(unknown.resultState, "unknown")
        await unknown.approve(approval.id)
        await unknown.choose("request")
        let attempts = try await submissions(unknown)
        XCTAssertEqual(attempts, 1)
    }

    func testRemoteNavigationAndScriptNetworkRequestsAreBlocked() async throws {
        let browser = make()
        defer { browser.stop() }
        try await open(browser)
        let fetched = try await browser.webView.callAsyncJavaScript(
            "try { await fetch('https://example.invalid/submit', {method:'POST'}); return true; } catch { return false; }",
            arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(fetched as? Bool, false)
        _ = try await browser.webView.evaluateJavaScript("location.href='https://example.invalid/commit'")
        for _ in 0..<100 where !browser.trace.contains(where: { $0.event == "navigation_refused" }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(browser.trace.contains { $0.event == "navigation_refused" })
        XCTAssertEqual(browser.webView.url?.absoluteString, "about:blank")
        let writes = try await submissions(browser)
        XCTAssertEqual(writes, 0)
    }
}
