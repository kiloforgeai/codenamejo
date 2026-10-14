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

    func refresh() {
        guard let owner = backend.userId else { commands = []; return }
        do { commands = try rows.all(userId: owner, profileId: Self.profileKey) }
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
    func save(keyword: String, label: String, actions: [CommandAction]) -> Outcome {
        let checked: (keyword: String, actions: [CommandAction])
        switch CustomCommandRules.validateSave(keyword: keyword, actions: actions) {
        case .failure(let refusal): return .refused(refusal.sentence)
        case .success(let value): checked = value
        }
        return write { owner, profile in
            .saved(try rows.save(userId: owner, profileId: profile, keyword: checked.keyword,
                                 spoken: keyword.trimmingCharacters(in: .whitespacesAndNewlines),
                                 label: label.trimmingCharacters(in: .whitespacesAndNewlines),
                                 actions: checked.actions))
        }
    }

    /// Delete one command, by exact keyword. A keyword that matches nothing is refused by name
    /// rather than reported done: losing a dictated command is the one unrecoverable thing here.
    func delete(keyword raw: String) -> Outcome {
        let keyword = CustomCommandRules.normalise(raw)
        guard !keyword.isEmpty else { return .refused("Say which command to delete.") }
        return write { owner, profile in
            guard let gone = try rows.delete(userId: owner, profileId: profile, keyword: keyword) else {
                return .refused("There is no command called \"\(keyword)\". Nothing was deleted — read the "
                    + "list back before trying again.")
            }
            return .saved(gone)
        }
    }

    /// Switch one command on or off, by exact keyword.
    func setEnabled(keyword raw: String, to enabled: Bool) -> Outcome {
        let keyword = CustomCommandRules.normalise(raw)
        guard !keyword.isEmpty else { return .refused("Say which command to switch.") }
        return write { owner, profile in
            guard let row = try rows.setEnabled(userId: owner, profileId: profile, keyword: keyword, enabled: enabled)
            else { return .refused("There is no command called \"\(keyword)\".") }
            return .saved(row)
        }
    }

    /// The Settings toggle. Same path as the voice tool.
    func toggle(_ command: CustomCommand, to enabled: Bool) {
        _ = setEnabled(keyword: command.keyword, to: enabled)
    }

    /// One write, then the whole list re-read, so the array cannot drift from the table.
    private func write(_ body: (_ owner: String, _ profile: String) throws -> Outcome) -> Outcome {
        guard let owner = backend.userId else { return .failed("Not signed in.") }
        do {
            let outcome = try body(owner, Self.profileKey)
            refresh()
            return outcome
        } catch {
            RealtimeLog.log("commands: write failed — \(error.localizedDescription)")
            return .failed("That didn't save — \(error.localizedDescription)")
        }
    }
}
