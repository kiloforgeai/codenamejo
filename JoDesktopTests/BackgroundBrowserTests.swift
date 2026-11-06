import FactoryKit
import XCTest
@testable import CodenameJo

@MainActor
final class BackgroundBrowserTests: XCTestCase {
    private var server: BrowserHTTPFixture!
    private var base: URL!
    override func setUp() async throws {
        server = BrowserHTTPFixture()
        base = try await server.start()
    }
    override func tearDown() async throws { server.stop() }
    private func make(current: @escaping () -> Bool = { true }) -> BackgroundBrowser {
        let job = DispatchJob(id: UUID(), task: "Read workshop times", state: "running", userId: "browser-owner",
            origin: .init(account: "fixture@example.test", messageID: "A", threadID: "thread-A", sender: "Fixture", subject: "Workshop"))
        let browser = BackgroundBrowser(job: job, current: current)
        browser.allowLocalFixture = true
        browser.beforeSubmit = { true }
        return browser
    }
    private func open(_ browser: BackgroundBrowser, path: String = "/event", key: String = UUID().uuidString) async throws -> String {
        _ = try await browser.open(URL(string: base.absoluteString + path + "?" + key)!)
        return key
    }
    private func control(_ browser: BackgroundBrowser, label: String) throws -> BackgroundBrowser.Control {
        try XCTUnwrap(browser.controls.first { $0.label == label })
    }

    func testBackgroundJavaScriptClickLoadsActualServerContentInIsolatedContexts() async throws {
        let first = make(), second = make()
        defer { first.cancel(); second.cancel() }
        _ = try await open(first)
        _ = try await open(second)
        XCTAssertFalse(first.text.contains("Tuesday"))
        let button = try control(first, label: "See times")
        _ = try await first.click(button.id, revision: first.revision, receipt: nil)
        XCTAssertTrue(first.text.contains("Tuesday 10 am"))
        XCTAssertFalse(second.text.contains("Tuesday"))
        _ = try await first.webView?.evaluateJavaScript("localStorage.setItem('owner','FIRST BROWSER')")
        _ = try await open(second)
        XCTAssertTrue(second.text.contains("Unclaimed browser"))
        XCTAssertFalse(second.text.contains("FIRST BROWSER"))
        XCTAssertEqual(first.origin?.messageID, "A")
        XCTAssertEqual(second.origin?.account, "fixture@example.test")
        let focus = try await first.webView?.evaluateJavaScript("document.hasFocus()") as? Bool
        XCTAssertEqual(focus, false, "A hidden browser must not claim keyboard focus")
    }

    func testFormRequiresExactApprovalAndConfirmsActualReceiptWithoutDuplicateSubmission() async throws {
        let browser = make(); defer { browser.cancel() }
        let key = try await open(browser)
        let field = try control(browser, label: "Guest name")
        _ = try await browser.fill(field.id, revision: browser.revision, value: "Synthetic guest")
        let submit = try control(browser, label: "Request place")
        _ = try await browser.click(submit.id, revision: browser.revision, receipt: "Request received; host approval pending.")
        XCTAssertEqual(browser.phase, .approval)
        let before = await server.count(key)
        XCTAssertEqual(before, 0)
        XCTAssertThrowsError(try browser.approve(UUID()))
        let approval = try XCTUnwrap(browser.approval)
        try browser.approve(approval.id)
        _ = try await browser.click(approval.controlID, revision: approval.revision, receipt: approval.receipt)
        XCTAssertTrue(browser.lastSubmissionConfirmed)
        XCTAssertTrue(browser.text.contains("Request received; host approval pending."))
        let after = await server.count(key)
        XCTAssertEqual(after, 1)
        _ = try await open(browser, key: key)
        _ = try await browser.fill(try control(browser, label: "Guest name").id, revision: browser.revision, value: "Synthetic guest")
        do {
            _ = try await browser.click(try control(browser, label: "Request place").id, revision: browser.revision, receipt: approval.receipt)
            XCTFail("A new snapshot cannot authorize repeating the same submission")
        } catch { XCTAssertTrue(error.localizedDescription.contains("already attempted")) }
        let final = await server.count(key)
        XCTAssertEqual(final, 1)
    }

    func testUnknownSubmissionNeverRetriesAndPauseRetainsSamePage() async throws {
        let browser = make(); defer { browser.cancel() }
        let key = try await open(browser, path: "/unknown")
        let id = try control(browser, label: "Request place").id
        _ = try await browser.click(id, revision: browser.revision, receipt: "Request received; host approval pending.")
        let approval = try XCTUnwrap(browser.approval)
        try browser.approve(approval.id)
        _ = try await browser.click(id, revision: approval.revision, receipt: approval.receipt)
        XCTAssertEqual(browser.phase, .unknown)
        XCTAssertThrowsError(try browser.resume())
        let count = await server.count(key)
        XCTAssertEqual(count, 1)
        browser.cancel()
        XCTAssertEqual(browser.phase, .unknown)
    }

    func testChangedPageAndChangedScopeRefuseBeforeClick() async throws {
        var current = true
        let browser = make { current }; defer { browser.cancel() }
        _ = try await open(browser)
        let id = try control(browser, label: "See times").id
        let revision = browser.revision
        _ = try await browser.webView?.evaluateJavaScript("document.getElementById('details').innerText='Different action'")
        do { _ = try await browser.click(id, revision: revision, receipt: nil); XCTFail("Changed target clicked") }
        catch { XCTAssertTrue(error.localizedDescription.contains("changed")) }
        current = false
        do { _ = try await browser.inspect(); XCTFail("Cross-profile browser read") }
        catch { XCTAssertEqual(browser.phase, .paused) }
        XCTAssertEqual(browser.origin?.messageID, "A")
    }

    func testLoginTakeoverPauseResumeAndCancelKeepTaskIdentity() async throws {
        let browser = make(); defer { browser.cancel() }
        _ = try await open(browser, path: "/login")
        XCTAssertEqual(browser.phase, .takeover)
        XCTAssertFalse(browser.controls.contains { $0.label.lowercased().contains("password") })
        browser.takeOver()
        XCTAssertEqual(browser.webView?.isUserInteractionEnabled, true)
        _ = try await browser.webView?.evaluateJavaScript("document.querySelector('input').remove();document.body.innerHTML='<h1>Signed in fixture</h1>'")
        try browser.resume()
        _ = try await browser.inspect()
        XCTAssertEqual(browser.phase, .ready)
        XCTAssertEqual(browser.webView?.isUserInteractionEnabled, false)
        browser.pause()
        let identity = browser.jobID
        try browser.resume()
        XCTAssertEqual(browser.jobID, identity)
        let pending = Task { try await browser.open(base.appendingPathComponent("slow")) }
        try await Task.sleep(for: .milliseconds(30))
        browser.cancel()
        do { _ = try await pending.value; XCTFail("Cancelled navigation continued") } catch {}
        XCTAssertNil(browser.webView)
        XCTAssertEqual(browser.phase, .cancelled)
    }

    func testTimeoutIsActionableAndCancelledBrowserCannotBecomeCompleted() async throws {
        let browser = make(); defer { browser.cancel() }
        browser.navigationTimeout = 0.05
        do { _ = try await open(browser, path: "/slow"); XCTFail("Slow navigation must pause") }
        catch { XCTAssertTrue(browser.message.contains("timed out")) }
        XCTAssertEqual(browser.phase, .paused)
        XCTAssertTrue(browser.needsInput)
        browser.cancel(); browser.finish()
        XCTAssertEqual(browser.phase, .cancelled)
    }

    func testAmbiguousControlsNeedTakeoverAndLongSnapshotDeclaresTruncation() async throws {
        let browser = make(); defer { browser.cancel() }
        _ = try await open(browser)
        _ = try await browser.webView?.evaluateJavaScript("document.body.appendChild(document.getElementById('details').cloneNode(true));document.body.append('x'.repeat(25000))")
        _ = try await browser.inspect()
        XCTAssertTrue(browser.textTruncated)
        let button = try control(browser, label: "See times")
        do { _ = try await browser.click(button.id, revision: browser.revision, receipt: nil); XCTFail("Ambiguous control clicked") }
        catch { XCTAssertTrue(browser.message.contains("same label")) }
        XCTAssertEqual(browser.phase, .paused)
    }
}
