import Foundation

/// Builds the phone's correspondent directory by walking sent, inbox and drafts headers.
/// Separate from the mail cache, which never sees who the user writes to.
enum ContactScan {
    /// How many messages to read per folder: months of mail for most people, 2,500 quota
    /// units. The deadline usually ends a walk before this does.
    static let maxPerFolder = 500

    /// Ids per `messages.list` page. Gmail's own maximum.
    private static let pageSize = 100

    /// Ids per batched metadata request. `messages.get` costs 5 units, so 20 is 100 units,
    /// within the 150 per second `GmailQuota` budgets.
    private static let batchSize = 20

    /// How stale a directory may be before it is rebuilt.
    static let refreshInterval: TimeInterval = 24 * 60 * 60

    /// Folders read through `messages.list`, best signal first since a truncated walk keeps
    /// what it reached. Drafts are served by `users.drafts`, so they get their own pass.
    private static let folders = ["in:sent", "in:inbox"]

    /// How many drafts to read. Low because `draftDetail` has no batch form: one 5-unit
    /// request per draft.
    private static let maxDrafts = 25

    /// Walk one mailbox and rebuild its directory.
    ///
    /// - Parameter deadline: stop and write what has been gathered; a partial directory of
    ///   the newest mail beats none.
    /// - Parameter force: rebuild even if the last walk was recent. The manual trigger.
    /// - Returns: how many correspondents the mailbox now holds, or nil if it was skipped.
    @discardableResult
    static func run(
        token: String,
        account: String,
        store: ContactStore,
        deadline: Date,
        force: Bool = false
    ) async -> Int? {
        if !force, let state = await store.scanState(account: account),
           Date().timeIntervalSince(state.scannedAt) < refreshInterval {
            return nil
        }

        var found: [String: ContactStore.Contact] = [:]
        // The mailbox's own address is in the To or From of every message it walks and is
        // never the answer to "who is Sarah".
        let own = account.lowercased()
        var complete = true

        for folder in folders {
            // The folder, not the header, decides which counter a match increments.
            let sent = folder != "in:inbox"
            await walk(
                token: token, query: folder, deadline: deadline
            ) { detail in
                let when = Int64(detail.internalDate ?? "") ?? 0
                let people = MailAddress.list(detail.header("From"))
                    + MailAddress.list(detail.header("To"))
                for person in people where person.email != own {
                    record(person, sent: sent, when: when, account: account, into: &found)
                }
            }
            if Date() >= deadline {
                complete = false
                break
            }
        }

        // Drafts count as sent: the user has already chosen the recipient.
        if Date() < deadline {
            await walkDrafts(token: token, deadline: deadline) { detail in
                let when = Int64(detail.internalDate ?? "") ?? 0
                let people = MailAddress.list(detail.header("From"))
                    + MailAddress.list(detail.header("To"))
                for person in people where person.email != own {
                    record(person, sent: true, when: when, account: account, into: &found)
                }
            }
            if Date() >= deadline { complete = false }
        } else {
            complete = false
        }

        guard !found.isEmpty else {
            RealtimeLog.log("contacts: \(account) — walked and found nobody")
            return nil
        }

        // A finished walk replaces; a truncated one merges, so a short pass never deletes
        // what the last full walk found.
        let held: Int
        if complete {
            await store.replace(account: account, contacts: Array(found.values))
            held = found.count
        } else {
            held = await store.merge(account: account, contacts: Array(found.values))
        }
        RealtimeLog.log(
            "contacts: \(account) — \(found.count) correspondent(s) from "
                + (complete ? "a full walk" : "a truncated walk, \(held) held")
        )
        return held
    }

    /// One folder, newest first, up to `maxPerFolder`.
    /// - Returns: whether the folder was read to its end. A throttled page is not "nobody".
    private static func walk(
        token: String,
        query: String,
        deadline: Date,
        onMessage: (GmailAPI.MessageDetail) -> Void
    ) async -> Bool {
        var pageToken: String?
        var seen = 0

        while seen < maxPerFolder, Date() < deadline {
            let wanted = min(pageSize, maxPerFolder - seen)
            let page: GmailAPI.MessageList
            do {
                page = try await GmailAPI.messagePage(
                    token: token, query: query, limit: wanted, pageToken: pageToken)
            } catch {
                RealtimeLog.log("contacts: \(query) page failed — \(error)")
                return false
            }

            let ids = (page.messages ?? []).map(\.id)
            // An empty page is the folder ending, not a failure.
            guard !ids.isEmpty else { return true }
            seen += ids.count

            for chunk in stride(from: 0, to: ids.count, by: batchSize) {
                guard Date() < deadline else { return false }
                let slice = Array(ids[chunk..<min(chunk + batchSize, ids.count)])
                for detail in await GmailAPI.metadataBatch(token: token, ids: slice) {
                    onMessage(detail)
                }
            }

            guard let next = page.nextPageToken else { return true }
            pageToken = next
        }
        // Ran out of deadline, or stopped at the cap — neither read the whole folder.
        return seen >= maxPerFolder ? true : false
    }

    /// The drafts folder: one `drafts.list` for the ids, then `draftDetail` per draft.
    private static func walkDrafts(
        token: String,
        deadline: Date,
        onMessage: (GmailAPI.MessageDetail) -> Void
    ) async {
        var pageToken: String?
        var seen = 0

        while seen < maxDrafts, Date() < deadline {
            let wanted = min(pageSize, maxDrafts - seen)
            let page: GmailAPI.DraftList
            do {
                page = try await GmailAPI.draftPage(
                    token: token, limit: wanted, pageToken: pageToken)
            } catch {
                RealtimeLog.log("contacts: drafts page failed — \(error)")
                return
            }

            let drafts = page.drafts ?? []
            guard !drafts.isEmpty else { return }
            seen += drafts.count

            for draft in drafts {
                guard Date() < deadline else { return }
                guard let detail = try? await GmailAPI.draftDetail(token: token, id: draft.id),
                      let message = detail.message
                else { continue }
                onMessage(message)
            }

            guard let next = page.nextPageToken else { return }
            pageToken = next
        }
    }

    /// Merge one address into the tally.
    private static func record(
        _ person: MailAddress.Parsed,
        sent: Bool,
        when: Int64,
        account: String,
        into found: inout [String: ContactStore.Contact]
    ) {
        var contact = found[person.email] ?? ContactStore.Contact(
            account: account,
            email: person.email,
            displayName: person.name,
            sentTo: 0,
            receivedFrom: 0,
            lastSeen: 0
        )
        if sent { contact.sentTo += 1 } else { contact.receivedFrom += 1 }
        if when > contact.lastSeen { contact.lastSeen = when }
        // Keep the first real name we got — plenty of headers carry a bare address.
        if contact.displayName.isEmpty { contact.displayName = person.name }
        found[person.email] = contact
    }
}
