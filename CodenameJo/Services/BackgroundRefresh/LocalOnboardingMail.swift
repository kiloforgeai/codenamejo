import FactoryKit
import Foundation

/// Picks onboarding's mail on the phone: recent important threads and one promotional sender worth a
/// cleanup offer, for the steps `prompts/onboarding/config.json` names (v1: fixed steps 2–4).
enum LocalOnboardingMail {
    private struct Pick { let query: String; let count: Int; let step: Int? }
    private static let importantQuery = "in:inbox is:important newer_than:7d"
    private static let promotionsQuery = "in:inbox category:promotions"
    private static let importantLimit = 10
    private static let promotionsLimit = 20
    private static let countCap = 500

    private static let promotionsNote =
        "This is a Gmail Promotions message whose available cleanup action is archive. Do not "
        + "mention unsubscribe availability, route safety, or verification. Say this shape, "
        + "substituting the sender's display name and exact count: 'You have [count] "
        + "promotional emails from [sender] in your inbox. I can archive this batch. Shall I "
        + "do that? You can also ask me to handle this email another way.' Say 'at least "
        + "[count]' when atLeast is true. Then wait. Only an explicit "
        + "yes to that immediately preceding offer authorizes one dispatch using "
        + "cleanup.dispatch; never call modify_matching inline. If they ask who the sender is, "
        + "how many there are, or what the offer means, answer from the current item and "
        + "cleanup fields, repeat the same archive question, and wait; do not call triage_next. "
        + "That repeated offer is the new immediate approval context. A no, skip, interruption, "
        + "unrelated topic change, silence, acknowledgement, or ambiguous answer does not "
        + "authorize it. A request for any other supported email action or compatible "
        + "combination leaves the cleanup flow and handles this email normally. Never say the "
        + "offer only supports archiving."
        + " For [sender], use cleanup.senderDisplayName exactly. The first sender "
        + "reference must be that actual name and must never be 'this sender'; only the later "
        + "reference may say 'this sender'."

    static func prepare(flow: EmailOnboardingFlow, store: MailStore) async -> EmailOnboardingSelection {
        let started = Date()
        let accounts = await MainActor.run { GoogleCredential.storedAccounts() }
        guard !accounts.isEmpty else {
            return .init(items: [], failures: ["The remaining onboarding emails could not be loaded."])
        }
        var failures: [String] = []
        var excluded = Set<String>()
        if let welcome = flow.welcome { excluded.insert("\(welcome.account):\(welcome.threadId)") }

        // A nil step is v1's numbering: important mail takes 2 and 3, cleanup takes 4.
        let steps = flow.config?.steps.enumerated().map { ($0.offset + 1, $0.element) }
        let importantPicks = steps.map { $0.filter { $0.1.kind == "important" }.map {
            Pick(query: $0.1.query ?? importantQuery, count: min(max($0.1.count ?? 2, 1), 3), step: $0.0) } }
            ?? [Pick(query: importantQuery, count: 2, step: nil)]
        let cleanupPicks = steps.map { $0.filter { $0.1.kind == "cleanup" }.map {
            Pick(query: $0.1.query ?? promotionsQuery, count: 1, step: $0.0) } }
            ?? [Pick(query: promotionsQuery, count: 1, step: 4)]

        var important: [String: [MailStore.Message]] = [:]
        var promotions: [String: [MailStore.Message]] = [:]
        for account in accounts {
            guard case .success(let token) = await GoogleCredential.token(for: account) else { continue }
            for query in Set(importantPicks.map(\.query)) {
                do {
                    important[query, default: []] += try await fetch(query, limit: importantLimit,
                                                 token: token.accessToken, account: account, store: store)
                } catch {
                    RealtimeLog.log("onboarding: important lookup failed — \(error)")
                    failures.append("Recent important emails could not be loaded.")
                }
            }
            for query in Set(cleanupPicks.map(\.query)) {
                do {
                    promotions[query, default: []] += try await fetch(query, limit: promotionsLimit,
                                                  token: token.accessToken, account: account, store: store)
                } catch {
                    RealtimeLog.log("onboarding: promotions lookup failed — \(error)")
                    failures.append("The promotional cleanup could not be checked.")
                }
            }
        }

        var items: [EmailOnboardingItem] = []
        for pick in importantPicks {
            var kept = 0
            for message in newestFirst(important[pick.query] ?? []) where kept < pick.count {
                let key = "\(message.account):\(message.threadId)"
                guard !excluded.contains(key) else { continue }
                excluded.insert(key)
                items.append(item(message, step: pick.step ?? items.count + 2, cleanup: nil))
                kept += 1
            }
        }
        let importantKept = items.count

        var seenSenders = Set<String>()
        var counted = 0
        for pick in cleanupPicks {
            promotionsLoop: for message in newestFirst(promotions[pick.query] ?? []) {
                let key = "\(message.account):\(message.threadId)"
                guard !excluded.contains(key), let from = message.sender,
                      let query = EmailCleanupPolicy.query(category: .promotions, from: from),
                      !seenSenders.contains("\(message.account):\(query)"),
                      case .success(let token) = await GoogleCredential.token(for: message.account)
                else { continue }
                seenSenders.insert("\(message.account):\(query)")
                do {
                    let page = try await GmailAPI.messagePage(token: token.accessToken, query: query, limit: countCap)
                    let matching = page.messages ?? []
                    counted += 1
                    let decision = EmailCleanupDecision(
                        category: .promotions, action: .archive, senderInboxCount: matching.count,
                        atLeast: page.nextPageToken != nil, matchingMessageIDs: matching.map(\.id))
                    let input = EmailCleanupInput(account: message.account, id: message.id, from: from)
                    guard let payload = EmailCleanupPolicy.cleanupPayload(item: input, decision: decision),
                          let dispatch = payload["dispatch"] as? [String: Any],
                          let task = dispatch["task"] as? String
                    else {
                        RealtimeLog.log("onboarding: promotions sender #\(counted) \(query) → \(matching.count) rejected")
                        continue
                    }
                    RealtimeLog.log("onboarding: promotions sender #\(counted) \(query) → \(matching.count) accepted")
                    let cleanup = EmailOnboardingItem.Cleanup(
                        senderInboxCount: matching.count, atLeast: page.nextPageToken != nil,
                        senderDisplayName: EmailCleanupPolicy.displayName(from), query: query,
                        account: message.account, messageId: message.id, note: promotionsNote,
                        dispatch: .init(task: task, account: message.account, expects: "receipt",
                                        facts: dispatch["facts"] as? [String] ?? []))
                    excluded.insert(key)
                    items.append(item(message, step: pick.step ?? 4, cleanup: cleanup))
                    break promotionsLoop
                } catch {
                    RealtimeLog.log("onboarding: promotions count failed — \(error)")
                    failures.append("The promotional cleanup could not be checked.")
                    break promotionsLoop
                }
            }
        }

        RealtimeLog.log("onboarding: prepared on device — important hydrated \(important.values.joined().count) kept "
            + "\(importantKept) · promotions hydrated \(promotions.values.joined().count) "
            + "senders counted \(counted) kept \(items.count - importantKept) in "
            + "\(Int(Date().timeIntervalSince(started) * 1000)) ms")
        return .init(items: items, failures: Array(Set(failures)))
    }

    struct AboutSender: Encodable, Sendable {
        let account: String
        let from: String
        var count: Int
    }

    /// Primary mail says who they are; the other tabs say what they are into. Primary is named
    /// by exclusion: `category:primary` came back empty from the API on a mailbox full of it.
    private static let otherTabs = ["promotions", "social", "updates", "forums"]
    private static let aboutQueries = [
        ("newer_than:180d -from:me " + otherTabs.map { "-category:\($0)" }.joined(separator: " "), 100),
        ("newer_than:180d (" + otherTabs.map { "category:\($0)" }.joined(separator: " OR ") + ")", 150)]

    /// Who writes to them most, for the "about you" draft. The same cache-first fetch as the
    /// picks above; only sender and count leave the phone — no subject, no snippet.
    static func aboutSenders(store: MailStore, scope: ProfileRuntime.Scope?) async -> [AboutSender] {
        guard let scope, let allowed = scope.emails else {
            RealtimeLog.log("onboarding: about skipped — mailbox ownership unavailable")
            return []
        }
        let accounts = GoogleAccountStore.emails().filter { account in
            allowed.contains { $0.caseInsensitiveCompare(account) == .orderedSame }
        }
        var bySender: [String: AboutSender] = [:]
        for account in accounts {
            guard case .success(let token) = await GoogleCredential.token(for: account) else { continue }
            for (query, limit) in aboutQueries {
                guard let messages = try? await fetch(query, limit: limit, token: token.accessToken,
                                                      account: account, store: store) else { continue }
                for message in messages {
                    guard let sender = message.sender else { continue }
                    let key = address(sender)
                    guard key != account.lowercased() else { continue }
                    let source = account.lowercased() + ":" + key
                    bySender[source, default: AboutSender(account: account.lowercased(), from: sender, count: 0)].count += 1
                }
            }
        }
        return Array(bySender.values.sorted { $0.count > $1.count }.prefix(40))
    }

    private static func address(_ sender: String) -> String {
        guard let open = sender.lastIndex(of: "<"), let close = sender.lastIndex(of: ">"), open < close else {
            return sender.lowercased()
        }
        return sender[sender.index(after: open)..<close].lowercased()
    }

    /// One list, then a single batch for whatever the cache does not already hold.
    private static func fetch(
        _ query: String, limit: Int, token: String, account: String, store: MailStore
    ) async throws -> [MailStore.Message] {
        let refs = try await GmailAPI.recentMessageIds(token: token, query: query, limit: limit)
        guard !refs.isEmpty else { return [] }
        let ids = refs.map(\.id)
        var cached = await store.messages(ids: ids, account: account)
        let alreadyCached = cached.count
        let missing = Set(ids).subtracting(cached.map(\.id))
        // Gmail refuses a batch of more than 100 outright (400), so the about pass's 150 goes in pieces.
        let wanted = ids.filter { missing.contains($0) }
        for start in stride(from: 0, to: wanted.count, by: 50) {
            let details = await GmailAPI.metadataBatch(token: token, ids: Array(wanted[start..<min(start + 50, wanted.count)]))
            let ingests = details.map { MailStore.Ingest(detail: $0, account: account) }
            await store.cache(ingests)
            cached += ingests.map(\.message)
        }
        RealtimeLog.log("onboarding: \(query) listed \(refs.count) · cached \(alreadyCached) · fetched \(cached.count - alreadyCached) of \(missing.count)")
        return cached
    }

    private static func newestFirst(_ messages: [MailStore.Message]) -> [MailStore.Message] {
        messages.sorted {
            ($0.internalDate ?? 0, $1.id) > ($1.internalDate ?? 0, $0.id)
        }
    }

    private static func item(_ message: MailStore.Message, step: Int, cleanup: EmailOnboardingItem.Cleanup?) -> EmailOnboardingItem {
        let date = ISO8601DateFormatter().string(
            from: Date(timeIntervalSince1970: Double(message.internalDate ?? 0) / 1000))
        return EmailOnboardingItem(
            account: message.account, id: message.id, threadId: message.threadId,
            from: message.sender ?? "unknown sender", subject: message.subject ?? "(no subject)",
            date: date, snippet: message.snippet ?? "", internalDate: message.internalDate ?? 0,
            onboardingStep: step, cleanup: cleanup)
    }
}
