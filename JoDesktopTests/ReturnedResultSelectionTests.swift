import FactoryKit
import XCTest
@testable import CodenameJo

@MainActor
final class ReturnedResultSelectionTests: XCTestCase {
    func testOriginsPersistAcrossRestartAndRespectOwnerProfileAndConnectedAccount() async throws {
        Container.shared.manager.push()
        let oldProfile = ProfileRuntime.snapshot
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            Container.shared.manager.pop()
            ProfileRuntime.install(oldProfile)
            try? FileManager.default.removeItem(at: folder)
        }
        let backend = BackendService(restoringSession: false)
        backend.userId = "result-owner"
        Container.shared.backend.register { backend }
        ProfileRuntime.install(.init(profileId: "work", isDefault: false, emails: ["work@example.test"]))
        let path = folder.appendingPathComponent("jobs.json")
        let store = DispatchJobStore(url: path)
        let origin = DispatchJob.MailOrigin(account: "work@example.test", messageID: "R", threadID: "thread-R", sender: "Same sender", subject: "Same subject")
        let id = UUID()
        await store.begin(id: id, task: "Research", profileId: "work", origin: origin)
        XCTAssertNil(store.selectableResult(id, allowedAccounts: [origin.account]))
        await store.finish(id, state: "done", result: "A result mentioning an unrelated sender and subject")
        let restored = DispatchJobStore(url: path)
        XCTAssertEqual(restored.selectableResult(id, allowedAccounts: [origin.account])?.origin, origin)
        XCTAssertNil(restored.selectableResult(id, allowedAccounts: ["personal@example.test"]))
        ProfileRuntime.install(.init(profileId: "personal", isDefault: false, emails: [origin.account]))
        XCTAssertNil(restored.selectableResult(id, allowedAccounts: [origin.account]))
        ProfileRuntime.install(.init(profileId: "work", isDefault: false, emails: [origin.account]))
        backend.userId = "another-owner"
        XCTAssertNil(restored.selectableResult(id, allowedAccounts: [origin.account]))
    }

    func testAmbiguousHandoffsAndLegacyResultsCannotInventASource() throws {
        XCTAssertNil(DispatchJob.MailOrigin.from(["account": "work@example.test", "id": "", "messages": [["id": "A"], ["id": "B"]]]))
        let raw = #"{"id":"00000000-0000-0000-0000-000000000001","task":"Research","state":"done","result":"Subject R"}"#
        let old = try JSONDecoder().decode(DispatchJob.self, from: Data(raw.utf8))
        XCTAssertNil(old.origin)
        let invalid = GmailReadTools.json(["done": false, "presentedForOutcome": true, "dispatchOutcome": [:],
            "returnedWorkSelection": "not-a-job", "item": ["id": "R", "threadId": "R", "account": "work@example.test"]])
        XCTAssertNil(LiveEmailPresentation.Key.step(invalid))
    }
}
