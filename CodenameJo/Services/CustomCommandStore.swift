import FactoryKit
import Foundation

/// The user's own voice commands for the active profile — the one copy of them in memory.
///
/// **This store is the single writer, and that is the whole design.** Two things change a
/// command: the Toggle in Settings, and the `commands` tool the model calls mid-call. Both go
/// through the methods here, so a command switched off by voice redraws the Toggle, and one
/// switched off on screen is gone from the very next `commands` `run` — no re-dial.
///
/// Keyword and step checks are `CustomCommandRules`; rows are `CustomCommandRows`.
@MainActor
class CustomCommandStore: ObservableObject {
    @Injected(\.backend) private var backend
    @Injected(\.customCommandRows) private var rows

    /// Every saved command, newest first, enabled or not. Settings draws all of them — a
    /// switched-off command still has to be visible to be switched back on.
    @Published var commands: [CustomCommand] = []
    var labelLoader: (String) async throws -> [GmailManageTools.Label] = { account in
        try await GmailManageTools.labels(GmailReadTools.token(account))
    }

    /// What `run` and `list` hand the model: switched-on ones only. A switched-off command is
    /// *absent* rather than marked, so the model has nothing to follow.
    var enabledCommands: [CustomCommand] { commands.filter(\.enabled) }

    /// The default profile is `""`, so its commands survive the profile list being rebuilt.
    static var profileKey: String {
        guard let scope = ProfileRuntime.snapshot, !scope.isDefault else { return "" }
        return scope.profileId
    }

    func refresh() async {
        guard let owner = backend.userId else { commands = []; return }
        do { commands = try await rows.all(userId: owner, profileId: Self.profileKey) }
        catch { RealtimeLog.log("commands: could not read list — \(error.localizedDescription)") }
    }

    // MARK: - Writing

    /// What a write did, in the three shapes the caller has to tell apart: it worked, the user's
    /// phrasing was declined with a sentence to say, or it never landed.
    enum Outcome {
        case saved(CustomCommand?)
        case refused(String)
        case failed(String)
    }

    struct EditScope: Equatable {
        let owner: String
        let profile: String
    }
    var editScope: EditScope? { backend.userId.map { .init(owner: $0, profile: Self.profileKey) } }

    func edit(expected: CustomCommand?, scope: EditScope, keyword: String,
              label: String, actions: [CommandAction]) async -> Outcome {
        guard editScope == scope else { return .refused("The active profile changed. Reopen Commands before saving.") }
        let checked: (keyword: String, actions: [CommandAction])
        switch CustomCommandRules.validateSave(keyword: keyword, actions: actions) {
        case .failure(let error): return .refused(error.sentence)
        case .success(let value): checked = value
        }
        do {
            let command = try await rows.edit(userId: scope.owner, profileId: scope.profile, expected: expected,
                keyword: checked.keyword, spoken: keyword.trimmingCharacters(in: .whitespacesAndNewlines),
                label: label.trimmingCharacters(in: .whitespacesAndNewlines), actions: checked.actions)
            await refresh()
            return .saved(command)
        } catch { return .failed(error.localizedDescription) }
    }

    /// Save a command, or change what an existing keyword does.
    func save(keyword: String, label: String, actions: [CommandAction]) async -> Outcome {
        let checked: (keyword: String, actions: [CommandAction])
        switch CustomCommandRules.validateSave(keyword: keyword, actions: actions) {
        case .failure(let refusal): return .refused(refusal.sentence)
        case .success(let value): checked = value
        }
        return await write { owner, profile in
            .saved(try await rows.save(userId: owner, profileId: profile, keyword: checked.keyword,
                                 spoken: keyword.trimmingCharacters(in: .whitespacesAndNewlines),
                                 label: label.trimmingCharacters(in: .whitespacesAndNewlines),
                                 actions: checked.actions))
        }
    }

    func correctLabel(keyword: String, name: String, account: String) async -> Outcome {
        guard let owner = backend.userId else { return .failed("Not signed in.") }
        let profile = Self.profileKey
        do {
            let saved = try await rows.all(userId: owner, profileId: profile)
            guard let command = saved.first(where: { $0.keyword == CustomCommandRules.normalise(keyword) }) else {
                return .refused("That command does not exist. Read the command list first.")
            }
            let indices = command.actions.indices.filter {
                ["label_message", "gmail_label_message"].contains(command.actions[$0].tool)
            }
            guard indices.count == 1 else {
                return .refused("The command must have exactly one label step to correct it; save the full command otherwise.")
            }
            let accounts = try GmailReadTools.targets(account.isEmpty ? [:] : ["account": account])
            let target = try GmailManageTools.single(accounts)
            let token = try await GmailReadTools.token(target)
            guard let label = try await GmailManageTools.findLabel(token, name), label.user else {
                return .refused("That user label was not found. List the labels and choose an existing label.")
            }
            var actions = command.actions
            let old = actions[indices[0]].resolvedLabel
            var mappings = old?.name.caseInsensitiveCompare(label.name) == .orderedSame ? old?.mappings ?? [:] : [:]
            mappings[target.lowercased()] = label.id
            actions[indices[0]].resolvedLabel = .init(id: label.id, name: label.name, account: target,
                scope: old?.scope, mappings: mappings)
            actions[indices[0]].detail = "Apply the saved label \(label.name)."
            guard backend.userId == owner, Self.profileKey == profile else {
                return .refused("The active profile changed. The command correction was not saved.")
            }
            guard let corrected = try await rows.correctLabel(userId: owner, profileId: profile,
                                                              expected: command, actions: actions) else {
                return .refused("The command changed while its label was being checked. Read it again before correcting it.")
            }
            await refresh()
            return .saved(corrected)
        } catch { return .failed("The command correction did not save: \(error.localizedDescription)") }
    }

    func resolveLabels(_ steps: [CommandAction], keyword: String?, account: String?,
                       ownerID: String?, profileID: String?) async throws -> [CommandAction] {
        guard steps.contains(where: { $0.resolvedLabel != nil }) else { return steps }
        guard let scope = editScope, scope.owner == ownerID, ProfileRuntime.snapshot?.profileId == profileID,
              let account, !account.isEmpty, let keyword else {
            throw CustomCommandRules.Refusal("The command's source or profile is unavailable. Select its original email and retry.")
        }
        if let reason = CustomCommandRules.accountRefusal(steps, account: account) { throw CustomCommandRules.Refusal(reason) }
        _ = try GmailReadTools.targets(["account": account])
        let labels = try await labelLoader(account)
        guard editScope == scope, ProfileRuntime.snapshot?.profileId == profileID else {
            throw CustomCommandRules.Refusal("The profile changed while checking labels. Nothing was changed.")
        }
        _ = try GmailReadTools.targets(["account": account])
        guard let saved = try await rows.all(userId: scope.owner, profileId: scope.profile).first(where: { $0.keyword == keyword }), saved.enabled else {
            throw CustomCommandRules.Refusal("That command is disabled or no longer exists.")
        }
        var actions = saved.actions
        var resolved = steps
        for index in steps.indices {
            guard let requested = steps[index].resolvedLabel else { continue }
            let matches = labels.filter { $0.user && $0.name.caseInsensitiveCompare(requested.name) == .orderedSame }
            guard matches.count == 1, let label = matches.first else {
                throw CustomCommandRules.Refusal("\(matches.isEmpty ? "Missing" : "Ambiguous") label “\(requested.name)” in \(account). Choose its existing label in Commands; no command steps were run.")
            }
            let savedIndices = actions.indices.filter { i in
                let current = actions[i].resolvedLabel
                return actions[i].tool == steps[index].tool && actions[i].detail == steps[index].detail
                    && current?.name == requested.name && current?.effectiveScope == requested.effectiveScope
                    && current?.account == requested.account
            }
            guard !savedIndices.isEmpty else { throw CustomCommandRules.Refusal("The command changed. Read its current definition before retrying.") }
            for i in savedIndices {
                var mapping = actions[i].resolvedLabel?.mappings ?? [requested.account.lowercased(): requested.id]
                mapping[account.lowercased()] = label.id
                actions[i].resolvedLabel?.mappings = mapping
            }
            resolved[index].resolvedLabel = .init(id: label.id, name: label.name, account: account, scope: .savedAccount)
        }
        if actions != saved.actions {
            guard try await rows.correctLabel(userId: scope.owner, profileId: scope.profile, expected: saved, actions: actions) != nil else {
                throw CustomCommandRules.Refusal("The command changed while checking its labels. Nothing was run; retry its current definition.")
            }
            await refresh()
        }
        guard editScope == scope, ProfileRuntime.snapshot?.profileId == profileID else {
            throw CustomCommandRules.Refusal("The profile changed. No command steps were run.")
        }
        return resolved
    }

    /// Delete one command, by exact keyword. A keyword that matches nothing is refused by name
    /// rather than reported done: losing a dictated command is the one unrecoverable thing here.
    func delete(keyword raw: String) async -> Outcome {
        let keyword = CustomCommandRules.normalise(raw)
        guard !keyword.isEmpty else { return .refused("Say which command to delete.") }
        return await write { owner, profile in
            guard let gone = try await rows.delete(userId: owner, profileId: profile, keyword: keyword) else {
                return .refused("There is no command called \"\(keyword)\". Nothing was deleted — read the "
                    + "list back before trying again.")
            }
            return .saved(gone)
        }
    }

    /// Switch one command on or off, by exact keyword.
    func setEnabled(keyword raw: String, to enabled: Bool) async -> Outcome {
        let keyword = CustomCommandRules.normalise(raw)
        guard !keyword.isEmpty else { return .refused("Say which command to switch.") }
        return await write { owner, profile in
            guard let row = try await rows.setEnabled(userId: owner, profileId: profile, keyword: keyword, enabled: enabled)
            else { return .refused("There is no command called \"\(keyword)\".") }
            return .saved(row)
        }
    }

    /// The Settings toggle. Same path as the voice tool.
    func toggle(_ command: CustomCommand, to enabled: Bool) {
        Task { _ = await setEnabled(keyword: command.keyword, to: enabled) }
    }

    /// One write, then the whole list re-read, so the array cannot drift from the table.
    private func write(_ body: (_ owner: String, _ profile: String) async throws -> Outcome) async -> Outcome {
        guard let owner = backend.userId else { return .failed("Not signed in.") }
        do {
            let outcome = try await body(owner, Self.profileKey)
            await refresh()
            return outcome
        } catch {
            RealtimeLog.log("commands: write failed — \(error.localizedDescription)")
            return .failed("That didn't save — \(error.localizedDescription)")
        }
    }
}
