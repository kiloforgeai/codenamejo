import AuthenticationServices
import XCTest
@testable import CodenameJo

@MainActor
final class WebAuthReplyTests: XCTestCase {
    func testSuccessfulCallbackFromBackgroundQueueReturnsOnMainThread() async throws {
        let callback = URL(string: "aurex://callback?code=test&state=test")!
        let result: URL = try await withCheckedThrowingContinuation { continuation in
            let reply = WebAuthReply {
                XCTAssertTrue(Thread.isMainThread)
                continuation.resume(with: $0)
            }
            DispatchQueue.global().async { reply.receive(callback, nil) }
        }
        XCTAssertEqual(result, callback)
    }

    func testBrowserCancellationFromBackgroundQueuePreservesCancellationError() async {
        let error = NSError(domain: ASWebAuthenticationSessionError.errorDomain,
                            code: ASWebAuthenticationSessionError.canceledLogin.rawValue)
        do {
            let _: URL = try await withCheckedThrowingContinuation { continuation in
                let reply = WebAuthReply { continuation.resume(with: $0) }
                DispatchQueue.global().async { reply.receive(nil, error) }
            }
            XCTFail("Cancellation should throw")
        } catch {
            XCTAssertEqual((error as NSError).domain, ASWebAuthenticationSessionError.errorDomain)
            XCTAssertEqual((error as NSError).code, ASWebAuthenticationSessionError.canceledLogin.rawValue)
        }
    }

    func testMissingCallbackAndErrorFailsInsteadOfHanging() async {
        do {
            let _: URL = try await withCheckedThrowingContinuation { continuation in
                let reply = WebAuthReply { continuation.resume(with: $0) }
                DispatchQueue.global().async { reply.receive(nil, nil) }
            }
            XCTFail("A missing callback should throw")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .badServerResponse)
        }
    }

    func testFailedStartAndLateCallbacksCompleteOnlyOnce() async {
        var results: [Result<URL, Error>] = []
        let reply = WebAuthReply { results.append($0) }
        reply.finish(.failure(URLError(.cannotOpenFile)))
        reply.receive(URL(string: "aurex://late-callback")!, nil)
        reply.receive(nil, CancellationError())
        // Queue a main-actor turn after both received callbacks.
        await Task { @MainActor in }.value
        XCTAssertEqual(results.count, 1)
        if case .failure(let error) = results.first {
            XCTAssertEqual((error as? URLError)?.code, .cannotOpenFile)
        } else { XCTFail("The original start failure must win") }
    }

    func testCompletionCanReenterWithoutResumingTwice() {
        var count = 0
        var reply: WebAuthReply!
        reply = WebAuthReply { _ in
            count += 1
            reply.finish(.failure(CancellationError()))
        }
        reply.finish(.success(URL(string: "aurex://callback")!))
        XCTAssertEqual(count, 1)
    }

    func testAlreadyCancelledTaskDoesNotOpenABrowser() async {
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await WebAuthSheet.present(URL(string: "https://example.test")!, callbackScheme: "aurex")
        }
        do { _ = try await task.value; XCTFail("Should cancel before starting a session") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testCancelledGoogleFlowReturnsCancellationWithoutOpeningBrowser() async {
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await GoogleSignInFlow.run(hint: nil, isPrimary: false)
        }
        if case .failure(.cancelled) = await task.value {} else {
            XCTFail("An explicit cancellation must not be reported as a sign-in failure")
        }
    }
}
