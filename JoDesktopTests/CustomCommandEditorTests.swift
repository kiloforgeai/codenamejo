import FactoryKit
import XCTest
@testable import CodenameJo

@MainActor
final class CustomCommandEditorTests: XCTestCase {
    private var path: URL!
    private var context: LocalContextStore!
    private var backend: BackendService!
    private var store: CustomCommandStore!
    private var rows: CustomCommandRows { .init(dbPool: context.dbPool) }
    private let actions = [CommandAction(tool: "web_search", detail: "Look up the sender.")]

    override func setUp() async throws {
        try await super.setUp()
        Container.shared.manager.push()
        ProfileRuntime.install(nil)
        path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        context = LocalContextStore(url: path)
        backend = BackendService(restoringSession: false)
        backend.userId = "alice"
        let backend = backend!
        let database = context.dbPool
        Container.shared.backend.register { backend }
        Container.shared.customCommandRows.register { .init(dbPool: database) }
        store = CustomCommandStore()
    }
    override func tearDown() async throws {
        Scope.singleton.reset()
        Container.shared.manager.pop()
        ProfileRuntime.install(nil)
        try context.dbPool?.close()
        try? FileManager.default.removeItem(at: path)
        try await super.tearDown()
    }
    private func create(_ phrase: String = "research") async throws -> CustomCommand {
        guard case .saved(let command) = await store.save(keyword: phrase, label: "Research", actions: actions) else {
            throw CustomCommandRows.Unavailable()
        }
        return try XCTUnwrap(command)
    }

    func testRenameAndStepsPersistWithIdentityAndDisabledState() async throws {
        let first = try await create()
        _ = await store.setEnabled(keyword: first.keyword, to: false)
        let original = try XCTUnwrap(store.commands.first)
        let scope = try XCTUnwrap(store.editScope)
        let revisedActions = [CommandAction(tool: "summarize", detail: "Tell me what matters.")]
        guard case .saved(let updated) = await store.edit(expected: original, scope: scope,
            keyword: "  Brief   Me ", label: "A useful brief", actions: revisedActions) else { return XCTFail("not saved") }
        let reopened = CustomCommandStore()
        await reopened.refresh()
        XCTAssertEqual(reopened.commands.count, 1)
        XCTAssertEqual(reopened.commands.first, updated)
        XCTAssertEqual(updated?.id, first.id)
        XCTAssertEqual(updated?.createdAt, first.createdAt)
        XCTAssertEqual(updated?.keyword, "brief me")
        XCTAssertEqual(updated?.actions, revisedActions)
        XCTAssertEqual(updated?.instruction, "A useful brief")
        XCTAssertEqual(updated?.enabled, false)
    }

    func testStaleEditorCannotOverwriteAVoiceCorrectionOrResurrectDeletedCommand() async throws {
        let first = try await create()
        let scope = try XCTUnwrap(store.editScope)
        _ = await store.save(keyword: first.keyword, label: "Voice correction", actions: [.init(tool: "summarize", detail: "New instructions")])
        guard case .failed(let message) = await store.edit(expected: first, scope: scope,
            keyword: first.keyword, label: "Old editor", actions: actions) else { return XCTFail("overwrote newer edit") }
        XCTAssertTrue(message.contains("changed"))
        XCTAssertEqual(store.commands.first?.instruction, "Voice correction")
        _ = await store.delete(keyword: first.keyword)
        guard case .failed = await store.edit(expected: first, scope: scope,
            keyword: first.keyword, label: "", actions: actions) else { return XCTFail("resurrected deleted command") }
        let all = try await rows.all(userId: "alice", profileId: "")
        XCTAssertTrue(all.isEmpty)
    }

    func testDuplicatePhraseAndReservedOrEmptyCommandsFailWithoutOverwriting() async throws {
        let first = try await create()
        let other = try await create("brief")
        let scope = try XCTUnwrap(store.editScope)
        for expected in [first, nil] {
            guard case .failed(let reason) = await store.edit(expected: expected, scope: scope,
                keyword: "BRIEF", label: "Overwrite", actions: actions) else { return XCTFail("duplicate accepted") }
            XCTAssertTrue(reason.contains("already uses"))
        }
        for (phrase, steps) in [("archive", actions), ("five words in this phrase", actions), ("empty", [])] {
            guard case .refused = await store.edit(expected: nil, scope: scope, keyword: phrase,
                                                   label: "", actions: steps) else { return XCTFail("invalid command accepted") }
        }
        let all = try await rows.all(userId: "alice", profileId: "")
        XCTAssertEqual(Set(all.map(\.id)), [first.id, other.id])
        XCTAssertTrue(all.allSatisfy { $0.instruction == "Research" })
    }

    func testProfileAndOwnerChangesRefuseAnOpenEditor() async throws {
        let first = try await create()
        let scope = try XCTUnwrap(store.editScope)
        ProfileRuntime.install(.init(profileId: "personal", isDefault: false, emails: []))
        guard case .refused = await store.edit(expected: first, scope: scope, keyword: "renamed",
            label: "", actions: actions) else { return XCTFail("cross-profile write") }
        ProfileRuntime.install(nil)
        backend.userId = "bob"
        guard case .refused = await store.edit(expected: first, scope: scope, keyword: "renamed",
            label: "", actions: actions) else { return XCTFail("cross-owner write") }
        let original = try await rows.all(userId: "alice", profileId: "")
        let other = try await rows.all(userId: "bob", profileId: "")
        XCTAssertEqual(original, [first])
        XCTAssertTrue(other.isEmpty)
    }

    func testEditingLabelInstructionsInvalidatesResolvedLabelButMetadataEditsKeepIt() {
        let saved = CommandAction(tool: "label_message", detail: "Apply Receipts",
                                  resolvedLabel: .init(id: "label-1", name: "Receipts", account: "work@example.test"))
        var step = CommandDraft.Step(saved)
        XCTAssertEqual(step.action.resolvedLabel, saved.resolvedLabel)
        step.detail = "Apply Travel"
        XCTAssertNil(step.action.resolvedLabel)
        step.detail = saved.detail
        step.tool = "archive_message"
        XCTAssertNil(step.action.resolvedLabel)
    }

    func testStepBindingFollowsIdentityAcrossReorderingAndIgnoresRemovedSteps() throws {
        let model = CustomCommandsViewModel()
        model.draft = .init(command: nil, scope: try XCTUnwrap(store.editScope))
        model.draft?.steps.append(.init(.init(tool: "web_search", detail: "Search")))
        let first = try XCTUnwrap(model.draft?.steps.first)
        let binding = model.stepBinding(first)
        model.move(first.id, by: 1)
        binding.detail.wrappedValue = "Edited after moving"
        XCTAssertEqual(model.draft?.steps.last?.id, first.id)
        XCTAssertEqual(model.draft?.steps.last?.detail, "Edited after moving")
        XCTAssertEqual(model.draft?.steps.first?.detail, "Search")
        model.draft?.steps.removeAll { $0.id == first.id }
        XCTAssertEqual(binding.wrappedValue.id, first.id)
        binding.detail.wrappedValue = "Late text field callback"
        XCTAssertEqual(model.draft?.steps.count, 1)
        XCTAssertEqual(model.draft?.steps.first?.detail, "Search")
    }

    func testDismissedEditorBindingsRemainReadableWithoutWritingIntoAnotherDraft() throws {
        let model = CustomCommandsViewModel()
        let scope = try XCTUnwrap(store.editScope)
        model.draft = .init(command: nil, scope: scope)
        model.draft?.phrase = "Original phrase"
        let step = try XCTUnwrap(model.draft?.steps.first)
        let stepBinding = model.stepBinding(step)
        let phrase = model.field(\.phrase, default: "")
        model.draft = nil
        XCTAssertEqual(stepBinding.wrappedValue.id, step.id)
        XCTAssertEqual(phrase.wrappedValue, "Original phrase")
        stepBinding.detail.wrappedValue = "After dismissal"
        phrase.wrappedValue = "After dismissal"
        XCTAssertNil(model.draft)
        model.draft = .init(command: nil, scope: scope)
        stepBinding.detail.wrappedValue = "Old editor callback"
        phrase.wrappedValue = "Old editor callback"
        XCTAssertEqual(model.draft?.phrase, "")
        XCTAssertEqual(model.draft?.steps.first?.detail, "")
    }
}
