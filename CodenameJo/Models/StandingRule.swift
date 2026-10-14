import Foundation

/// The three automatic filing rules, enforced on the phone at the moment of the write.
/// The ids are a cross-repo contract: `auth:lib/standing-rules.ts` and `set_rule` key on them.
enum StandingRule: String, CaseIterable, Identifiable {
    case archiveAfterReply = "archive_after_reply"
    case archiveAfterForward = "archive_after_forward"
    case archiveAfterLabel = "archive_after_label"

    var id: String { rawValue }

    /// The `UserDefaults` key, which is also the profile field the broker reads.
    var storageKey: String {
        switch self {
        case .archiveAfterReply: "archiveAfterReply"
        case .archiveAfterForward: "archiveAfterForward"
        case .archiveAfterLabel: "archiveAfterLabel"
        }
    }

    var title: String {
        switch self {
        case .archiveAfterReply: "Archive after replying"
        case .archiveAfterForward: "Archive after forwarding"
        case .archiveAfterLabel: "Archive after filing"
        }
    }

    /// What it does, in the terms the user thinks in rather than the tool's.
    var detail: String {
        switch self {
        case .archiveAfterReply:
            "Answering an email takes it out of your inbox. Drafted replies count too."
        case .archiveAfterForward:
            "Handing an email to the right person is what clears it."
        case .archiveAfterLabel:
            "Filing an email under a label archives it in the same step."
        }
    }

    /// Off unless the account says otherwise — the same reading the broker takes. A rule the
    /// user has never seen must not start moving their mail.
    var isOn: Bool { UserDefaults.standard.bool(forKey: storageKey) }
}
