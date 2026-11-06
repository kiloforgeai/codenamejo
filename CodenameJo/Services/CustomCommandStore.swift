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
        await refresh()
        guard let command = commands.first(where: { $0.keyword == CustomCommandRules.normalise(keyword) }) else {
            return .refused("That command does not exist. Read the command list first.")
        }
        let indices = command.actions.indices.filter {
            ["label_message", "gmail_label_message"].contains(command.actions[$0].tool)
        }
        guard indices.count == 1 else {
            return .refused("The command must have exactly one label step to correct it; save the full command otherwise.")
        }
        do {
            let accounts = try GmailReadTools.targets(account.isEmpty ? [:] : ["account": account])
            let target = try GmailManageTools.single(accounts)
            let token = try await GmailReadTools.token(target)
            guard let label = try await GmailManageTools.findLabel(token, name), label.user else {
                return .refused("That user label was not found. List the labels and choose an existing label.")
            }
            var actions = command.actions
            actions[indices[0]].resolvedLabel = .init(id: label.id, name: label.name, account: target)
            actions[indices[0]].detail = "Apply the saved label \(label.name)."
            return await save(keyword: command.spoken.isEmpty ? command.keyword : command.spoken,
                              label: command.instruction, actions: actions)
        } catch { return .failed("The command correction did not save: \(error.localizedDescription)") }
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
