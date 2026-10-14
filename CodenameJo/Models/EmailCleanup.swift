import Foundation

struct EmailCleanupInput: Codable, Sendable {
    let account: String
    let id: String
    let from: String
}

enum GmailMailCategory: String, Codable, Equatable, Sendable {
    case promotions
    case purchases
    case reservations
    case updates
    case social
    case forums

    static func from(labels: [String]) -> GmailMailCategory? {
        let labels = Set(labels.map { $0.uppercased() })
        if labels.contains("CATEGORY_PROMOTIONS") { return .promotions }
        if labels.contains("CATEGORY_PURCHASES") || labels.contains("PURCHASES") {
            return .purchases
        }
        if labels.contains("CATEGORY_RESERVATIONS") || labels.contains("RESERVATIONS") {
            return .reservations
        }
        if labels.contains("CATEGORY_UPDATES") { return .updates }
        if labels.contains("CATEGORY_SOCIAL") { return .social }
        if labels.contains("CATEGORY_FORUMS") { return .forums }
        return nil
    }
}

struct EmailCleanupDecision: Sendable {
    enum Action: String, Sendable {
        case unsubscribe
        case archive
    }

    let category: GmailMailCategory
    let action: Action
    let senderInboxCount: Int
    let atLeast: Bool
    let matchingMessageIDs: [String]

    init(
        category: GmailMailCategory,
        action: Action,
        senderInboxCount: Int,
        atLeast: Bool,
        matchingMessageIDs: [String] = []
    ) {
        self.category = category
        self.action = action
        self.senderInboxCount = senderInboxCount
        self.atLeast = atLeast
        self.matchingMessageIDs = matchingMessageIDs
    }
}

enum EmailCleanupPolicy {
    static func minimumSuggestedCount(for category: GmailMailCategory) -> Int {
        category == .purchases ? 3 : 5
    }

    static let alternativeOfferSentence =
        "You can also ask me to handle this email another way."

    /// A cleanup proposal is a shortcut, not a mode that removes the ordinary mail tools.
    /// Kept here so the live queue prompt and its policy test cannot drift independently.
    static let alternativeActionGuidance = """
        The proactive cleanup is a recommendation, never an allowlist. If the user requests \
        any other supported email action or compatible combination — read, archive just this \
        message, trash, mark spam, label, reply, forward, draft, unsubscribe without \
        the offered archive, create a rule, or use another bulk scope — leave the cleanup \
        approval flow and follow the ordinary email rules for the current item. Never say the \
        offer only supports its proposed action. Do not dispatch cleanup.dispatch for an \
        alternative, and do not repeat the cleanup offer unless the user asks for it. If they \
        ask to mark the current message as spam and unsubscribe, call unsubscribe_sender for \
        the explicit current message and account with clear_existing false, then mark_spam on \
        that same explicit message and account; this does not authorize the offered batch archive.
        """

    static func sender(_ from: String) -> String? {
        let address: String
        if let start = from.firstIndex(of: "<"), let end = from[start...].firstIndex(of: ">") {
            address = String(from[from.index(after: start)..<end])
        } else {
            address = from
        }
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.range(
            of: #"^[a-z0-9._%+-]+@[a-z0-9-]+(?:\.[a-z0-9-]+)+$"#,
            options: .regularExpression) == nil ? nil : trimmed
    }

    static func query(category: GmailMailCategory, from: String) -> String? {
        guard category == .promotions || category == .purchases,
              let sender = sender(from) else { return nil }
        return "in:inbox category:\(category.rawValue) from:\(sender)"
    }

    private static let genericLocalParts: Set<String> = [
        "email", "hello", "info", "mail", "marketing", "news", "newsletter", "noreply",
        "notification", "notifications", "offers", "support", "team", "updates",
        "order", "orders", "receipt", "receipts", "billing", "invoice", "invoices",
        "shipping", "shipment", "shipments", "delivery", "confirmation", "confirmations",
    ]

    private static let twoPartPublicSuffixes: Set<String> = [
        "co.uk", "org.uk", "com.au", "co.nz", "co.jp", "com.br", "co.za", "co.in", "com.mx",
    ]

    /// Prefer the header name, then a meaningful local part, then the sending organization.
    static func displayName(_ from: String) -> String {
        let trimmed = from.trimmingCharacters(in: .whitespacesAndNewlines)
        var genericDisplay = false
        if let start = trimmed.firstIndex(of: "<"), start != trimmed.startIndex {
            let name = trimmed[..<start]
                .trimmingCharacters(in: CharacterSet(charactersIn: " \t\n\r\""))
            genericDisplay = genericLocalParts.contains(name.lowercased().filter { $0.isLetter || $0.isNumber })
            if !name.isEmpty, !name.contains("@"), !genericDisplay { return String(name.prefix(80)) }
        }
        guard let address = sender(from) else { return String(trimmed.prefix(80)) }
        let local = String(address.split(separator: "@", maxSplits: 1).first ?? "")
            .split(separator: "+", maxSplits: 1).first.map(String.init) ?? ""
        let compact = local.filter(\.isLetter).lowercased()
        if !genericDisplay, local.contains(where: \.isLetter), !genericLocalParts.contains(compact) {
            let words = local.split(whereSeparator: { "._-".contains($0) })
            let name = words.map { word in
                word.prefix(1).uppercased() + word.dropFirst().lowercased()
            }.joined(separator: " ")
            if !name.isEmpty { return String(name.prefix(80)) }
        }
        let host = address.split(separator: "@", maxSplits: 1).last.map(String.init) ?? ""
        let labels = host.split(separator: ".").map(String.init)
        let suffix = labels.suffix(2).joined(separator: ".")
        let organizationIndex = twoPartPublicSuffixes.contains(suffix)
            ? labels.count - 3
            : labels.count - 2
        let organization = labels.indices.contains(organizationIndex) ? labels[organizationIndex] : host
        guard !organization.isEmpty else { return String(trimmed.prefix(80)) }
        return organization.prefix(1).uppercased() + organization.dropFirst()
    }

    static func cleanupPayload(
        item: EmailCleanupInput, decision: EmailCleanupDecision
    ) -> [String: Any]? {
        guard decision.senderInboxCount >= minimumSuggestedCount(for: decision.category),
              let sender = sender(item.from),
              let query = query(category: decision.category, from: item.from),
              decision.category == .promotions || decision.category == .purchases
        else { return nil }

        let action = decision.action
        let task: String
        switch action {
        case .unsubscribe:
            guard decision.category == .promotions else { return nil }
            task = "Unsubscribe from the promotional sender represented by message_id "
                + "\(quoted(item.id)) and archive all matching Promotions inbox messages. Use "
                + "unsubscribe_sender once with message_id \(quoted(item.id)), account "
                + "\(quoted(item.account)), clear_existing true and clear_existing_query "
                + "\(quoted(query)). Do not widen the sender, category, query, or account, and "
                + "do not call modify_matching separately. Perform no other action."
        case .archive:
            task = "Archive all matching \(decision.category.rawValue) inbox messages from "
                + "this exact sender. Use modify_matching with action archive, account "
                + "\(quoted(item.account)) and query \(quoted(query)). Do not widen the sender, "
                + "category, query, or account. Perform no other action."
        }

        var facts = [
            "The approved offer reported "
                + (decision.atLeast ? "at least " : "")
                + "\(decision.senderInboxCount) matching inbox messages.",
            "The offer originated from message_id \(quoted(item.id)).",
        ]
        if action == .unsubscribe {
            facts.append(
                "The approval covered both unsubscribe and the exact Promotions batch archive.")
        }

        return [
            "category": decision.category.rawValue,
            "action": action.rawValue,
            "sender": sender,
            "senderDisplayName": displayName(item.from),
            "senderInboxCount": decision.senderInboxCount,
            "atLeast": decision.atLeast,
            "query": query,
            "account": item.account,
            "messageId": item.id,
            "requiresApproval": true,
            "state": "proposed",
            "dispatch": [
                "task": task,
                "account": item.account,
                "expects": "receipt",
                "facts": facts,
            ],
        ]
    }

    /// Match the app's complete cleanup instruction, including its scope restrictions.
    /// Its prose ("query, or account") is not a Gmail OR expression.
    static func generatedCleanupCategory(task: String, item: EmailCleanupInput) -> GmailMailCategory? {
        for category in [GmailMailCategory.promotions, .purchases] {
            for action in [EmailCleanupDecision.Action.archive, .unsubscribe] {
                let decision = EmailCleanupDecision(category: category, action: action,
                    senderInboxCount: minimumSuggestedCount(for: category), atLeast: false)
                let dispatch = cleanupPayload(item: item, decision: decision)?["dispatch"] as? [String: Any]
                if dispatch?["task"] as? String == task { return category }
            }
        }
        return nil
    }

    private static func quoted(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let text = String(data: data, encoding: .utf8)
        else { return "\"\"" }
        return text
    }
}
