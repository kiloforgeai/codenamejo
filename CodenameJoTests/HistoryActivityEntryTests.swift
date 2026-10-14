import XCTest
@testable import CodenameJo

// coverage-target: CodenameJo/Views/HistoryView.swift

/// History's Actions tab interleaves two kinds of row the broker writes — a write the
/// assistant performed (`ActionRecord`) and a read it dispatched (`DispatchJob`) — into one
/// list ordered newest first. `HistoryViewModel.ActivityEntry` is the only thing that
/// decides a row's identity and its place in that order. Its rule is deliberate: a row
/// still in flight sorts by when it *began*, so it cannot sink to the bottom for lacking a
/// completion — which is exactly the row most worth seeing.
@MainActor
final class HistoryActivityEntryTests: XCTestCase {

    private let epoch = Date(timeIntervalSince1970: 1_783_512_000)

    private func action(
        id: String, startedAt: String? = nil, completedAt: String? = nil, state: String = "done"
    ) throws -> ActionRecord {
        var json: [String: Any] = [
            "id": id, "tool": "archive_message", "connector": "gmail",
            "account": "owner@example.test", "summary": "Archived the invoice", "state": state,
        ]
        if let startedAt { json["started_at"] = startedAt }
        if let completedAt { json["completed_at"] = completedAt }
        return try decode(ActionRecord.self, json)
    }

    private func dispatch(
        id: String, task: String = "Check the inbox", startedAt: String? = nil,
        completedAt: String? = nil, state: String = "done"
    ) throws -> DispatchJob {
        var json: [String: Any] = ["id": id, "task": task, "state": state]
        if let startedAt { json["started_at"] = startedAt }
        if let completedAt { json["completed_at"] = completedAt }
        return try decode(DispatchJob.self, json)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: [String: Any]) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: JSONSerialization.data(withJSONObject: json))
    }

    func testAnActionRowKeepsTheActionsOwnIdentity() throws {
        let record = try action(id: "11111111-1111-1111-1111-111111111111")
        let entry = HistoryViewModel.ActivityEntry.action(record)
        XCTAssertEqual(entry.id, record.id)
    }

    func testADispatchRowKeepsTheJobsOwnIdentity() throws {
        let job = try dispatch(id: "22222222-2222-2222-2222-222222222222")
        let entry = HistoryViewModel.ActivityEntry.dispatch(job)
        XCTAssertEqual(entry.id, job.id)
    }

    func testTwoKindsOfRowNeverCollideOnOneIdentity() throws {
        let record = try action(id: "11111111-1111-1111-1111-111111111111")
        let job = try dispatch(id: "22222222-2222-2222-2222-222222222222")
        XCTAssertNotEqual(
            HistoryViewModel.ActivityEntry.action(record).id,
            HistoryViewModel.ActivityEntry.dispatch(job).id)
    }

    func testASettledWriteSortsByWhenItSettled() throws {
        let record = try action(
            id: "11111111-1111-1111-1111-111111111111",
            startedAt: "2026-07-08T12:00:00Z", completedAt: "2026-07-08T12:01:00Z")
        XCTAssertEqual(
            HistoryViewModel.ActivityEntry.action(record).sortDate,
            epoch.addingTimeInterval(60))
    }

    func testAWriteStillInFlightSortsByWhenItBegan() throws {
        let record = try action(
            id: "11111111-1111-1111-1111-111111111111",
            startedAt: "2026-07-08T12:00:00Z", state: "pending")
        XCTAssertTrue(record.isPending)
        XCTAssertEqual(HistoryViewModel.ActivityEntry.action(record).sortDate, epoch)
    }

    func testAWriteWithNoTimestampsAtAllSinksRatherThanCrashing() throws {
        let record = try action(id: "11111111-1111-1111-1111-111111111111", state: "pending")
        XCTAssertEqual(HistoryViewModel.ActivityEntry.action(record).sortDate, .distantPast)
    }

    func testASettledDispatchSortsByWhenItSettled() throws {
        let job = try dispatch(
            id: "22222222-2222-2222-2222-222222222222",
            startedAt: "2026-07-08T12:00:00Z", completedAt: "2026-07-08T12:05:00Z")
        XCTAssertEqual(
            HistoryViewModel.ActivityEntry.dispatch(job).sortDate,
            epoch.addingTimeInterval(300))
    }

    func testADispatchStillRunningSortsByWhenItBegan() throws {
        let job = try dispatch(
            id: "22222222-2222-2222-2222-222222222222",
            startedAt: "2026-07-08T12:00:00Z", state: "running")
        XCTAssertTrue(job.isRunning)
        XCTAssertEqual(HistoryViewModel.ActivityEntry.dispatch(job).sortDate, epoch)
    }

    func testWritesAndDispatchesInterleaveNewestFirstOffTheirOwnDates() throws {
        let oldWrite = try action(
            id: "11111111-1111-1111-1111-111111111111",
            startedAt: "2026-07-08T12:00:00Z", completedAt: "2026-07-08T12:01:00Z")
        let newWrite = try action(
            id: "33333333-3333-3333-3333-333333333333",
            startedAt: "2026-07-08T12:09:00Z", completedAt: "2026-07-08T12:10:00Z")
        let midJob = try dispatch(
            id: "22222222-2222-2222-2222-222222222222",
            startedAt: "2026-07-08T12:04:00Z", completedAt: "2026-07-08T12:05:00Z")
        let runningJob = try dispatch(
            id: "44444444-4444-4444-4444-444444444444",
            startedAt: "2026-07-08T12:20:00Z", state: "running")

        let entries: [HistoryViewModel.ActivityEntry] = [
            .action(oldWrite), .action(newWrite), .dispatch(midJob), .dispatch(runningJob),
        ]
        let order = entries.sorted { $0.sortDate > $1.sortDate }.map(\.id)
        XCTAssertEqual(order, [runningJob.id, newWrite.id, midJob.id, oldWrite.id],
                       "An unfinished dispatch leads on the time it started, not on a missing completion")
    }

    func testTheTabsOfferConversationsFirstAndActionsSecond() {
        XCTAssertEqual(HistoryViewModel.Grouping.allCases, [.conversations, .actions])
        XCTAssertEqual(HistoryViewModel.Grouping.conversations.rawValue, "Conversations")
        XCTAssertEqual(HistoryViewModel.Grouping.actions.rawValue, "Actions")
        XCTAssertEqual(HistoryViewModel().grouping, .conversations,
                       "The screen opens on the threads you can pick back up")
    }
}
