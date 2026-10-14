import FactoryKit
import Foundation

/// A call's turns whose History save failed, kept on disk and retried while their owner is signed in.
actor TurnSaveOutbox {
    private struct Entry: Codable {
        let owner: String
        let conversation: UUID
        var failedTurns: [CommandRecord]
        var revision: UUID
    }
    typealias Credentials = @Sendable (String) async -> String?
    typealias SaveTurn = @Sendable (CommandRecord, String, String) async -> Bool
    private let fileURL: URL?
    private let credentials: Credentials
    private let saveTurn: SaveTurn
    private let automaticallyRetry: Bool

    init(fileURL: URL? = nil, automaticallyRetry: Bool = true,
         credentials: @escaping Credentials = { owner in
             await TurnSaveOutbox.currentCredentials(owner: owner)
         },
         saveTurn: @escaping SaveTurn = { record, owner, token in
             await TurnSaveOutbox.retryTurn(record, owner: owner, token: token)
         }) {
        self.fileURL = fileURL
        self.automaticallyRetry = automaticallyRetry
        self.credentials = credentials
        self.saveTurn = saveTurn
    }

    private var entries: [String: Entry] = [:]
    private var loaded = false
    private var draining = false
    private var retry: Task<Void, Never>?

    /// The file keeps the name it had when it also triggered the server's dossier refresh.
    private var file: URL {
        fileURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("profile-dossier-refresh.json")
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do { entries = try JSONDecoder().decode([String: Entry].self, from: Data(contentsOf: file)) }
        catch { print("turnSaveOutbox: read failed: \(error.localizedDescription)") }
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(entries).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch { print("turnSaveOutbox: write failed: \(error.localizedDescription)") }
    }

    func enqueue(conversation: UUID, owner: String, failedTurns: [CommandRecord]) async {
        guard !failedTurns.isEmpty else { return }
        load()
        let key = owner + ":" + conversation.uuidString
        var failures = entries[key]?.failedTurns ?? []
        for turn in failedTurns where !failures.contains(where: { $0.id == turn.id }) { failures.append(turn) }
        entries[key] = Entry(owner: owner, conversation: conversation, failedTurns: failures, revision: UUID())
        persist()
        await drain()
    }

    func purge(owner: String) {
        load()
        entries = entries.filter { $0.value.owner != owner }
        persist()
        if entries.isEmpty { retry?.cancel(); retry = nil }
    }

    func drain() async {
        load()
        guard !draining else { return }
        draining = true
        defer { draining = false }
        for (key, original) in Array(entries) {
            guard let token = await credentials(original.owner) else { continue }
            var remaining: [CommandRecord] = []
            for turn in original.failedTurns {
                let saved = await saveTurn(turn, original.owner, token)
                if !saved { remaining.append(turn) }
            }
            guard entries[key]?.revision == original.revision else { continue }
            if remaining.isEmpty { entries.removeValue(forKey: key) } else { entries[key]?.failedTurns = remaining }
            persist()
        }
        if automaticallyRetry, !entries.isEmpty, retry == nil {
            retry = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(60)) }
                catch { return }
                await self?.retryDelivery()
            }
        }
    }

    var pendingTurns: Int { entries.values.reduce(0) { $0 + $1.failedTurns.count } }

    private func retryDelivery() async {
        retry = nil
        await drain()
    }

    @MainActor
    static func currentCredentials(owner: String) async -> String? {
        let backend = Container.shared.backend()
        guard backend.userId == owner, backend.isSignedIn else { return nil }
        return owner
    }

    @MainActor
    static func retryTurn(_ turn: CommandRecord, owner: String, token: String) async -> Bool {
        let backend = Container.shared.backend()
        guard backend.userId == owner, backend.isSignedIn else { return false }
        return await Container.shared.commandStore().save(turn, expectedUserId: owner)
    }
}
