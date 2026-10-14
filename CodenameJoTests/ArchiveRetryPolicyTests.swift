import XCTest
@testable import CodenameJo

final class ArchiveRetryPolicyTests: XCTestCase {
    private let job = PendingArchive(id: "job", account: "owner@example.test", messageId: "message", threadId: "thread")

    func testPendingTrashNeverSuppressesSiblingMessagesOrOtherMailboxes() {
        let pending = PendingArchive(id: "trash", account: job.account, messageId: "message",
                                     threadId: "thread", operation: "trash_message")
        XCTAssertTrue(pending.matches(account: job.account, ids: ["message"], threadId: "thread"))
        XCTAssertFalse(pending.matches(account: job.account, ids: ["sibling"], threadId: "thread"))
        XCTAssertFalse(pending.matches(account: "other@example.test", ids: ["message"], threadId: "thread"))
    }

    func testHealthyAndPendingReceiptsAreDistinct() {
        XCTAssertEqual(ArchiveReceiptPolicy.receipt(succeeded: true, pending: nil), "Archived.")
        XCTAssertEqual(ArchiveReceiptPolicy.receipt(succeeded: false, pending: job), "Archiving.")
        XCTAssertEqual(ArchiveReceiptPolicy.receipt(succeeded: false, pending: job, live: true), "Archived.")
        XCTAssertNil(ArchiveReceiptPolicy.receipt(succeeded: false, pending: nil))
    }

    func testPendingThreadIncludesOtherExchangesButNeverAnotherMailbox() {
        XCTAssertTrue(job.matches(account: "OWNER@example.test", ids: ["another"], threadId: "thread"))
        XCTAssertFalse(job.matches(account: "other@example.test", ids: ["message"], threadId: "thread"))
        XCTAssertFalse(job.matches(account: "owner@example.test", ids: ["another"], threadId: "different"))
    }

    func testPendingMessageWithoutKnownThreadDoesNotHideUnrelatedMail() {
        let pending = PendingArchive(id: "job", account: job.account, messageId: "message", threadId: nil)
        XCTAssertTrue(pending.matches(account: job.account, ids: ["message"], threadId: "thread"))
        XCTAssertFalse(pending.matches(account: job.account, ids: ["another"], threadId: "thread"))
    }
    func testDurableRetryIsNotAbandonedAfterSixtySeconds() throws {
        let json = """
        {"id":"11111111-1111-1111-1111-111111111111","tool":"archive_message",
         "connector":"gmail","account":"owner@example.test","summary":"Archiving",
         "state":"pending","started_at":"2026-09-08T10:00:00Z","retry_until":"2026-09-09T10:00:00Z"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var record = try decoder.decode(ActionRecord.self, from: Data(json.utf8))
        let later = record.startedAt!.addingTimeInterval(600)
        XCTAssertFalse(record.isAbandoned(asOf: later))
        record.retryUntil = nil
        XCTAssertTrue(record.isAbandoned(asOf: later), "Legacy single-request writes retain their timeout")
    }

}
