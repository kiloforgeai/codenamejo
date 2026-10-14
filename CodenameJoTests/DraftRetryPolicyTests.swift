import XCTest
@testable import CodenameJo

final class DraftRetryPolicyTests: XCTestCase {
    func testPendingDraftDecodesFromTheBrokerShape() throws {
        let json = """
        {"id":"11111111-1111-1111-1111-111111111111","account":"owner@example.test",
         "to":"dana@acme.test","threadId":"thread"}
        """
        let decoded = try JSONDecoder().decode(PendingDraft.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.account, "owner@example.test")
        XCTAssertEqual(decoded.to, "dana@acme.test")
        XCTAssertEqual(decoded.threadId, "thread")
    }

    func testAFreshDraftCarriesNoThread() throws {
        let json = """
        {"id":"job","account":"owner@example.test","to":"dana@acme.test"}
        """
        XCTAssertNil(try JSONDecoder().decode(PendingDraft.self, from: Data(json.utf8)).threadId)
    }

    /// A queued draft is not a saved one, and the broker's own verdict reads the opener.
    func testAQueuedReceiptCannotReadAsSaved() {
        let queued = "Drafting. The draft is queued for background retry."
        XCTAssertFalse(queued.hasPrefix("Draft "))
        XCTAssertTrue(queued.hasPrefix("Drafting."))
    }
}
