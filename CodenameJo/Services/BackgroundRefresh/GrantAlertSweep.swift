import FactoryKit
import Foundation

/// Archive the security notices Google sends about our own consent, so onboarding's queue opens on
/// Jo's mail. One sender, nothing older than the grant, and a cap: another sign-in's alert must stay.
@MainActor
enum GrantAlertSweep {
    /// The sender Google's account notices come from.
    private static let sender = "no-reply@accounts.google.com"

    /// One consent produces one or two. A larger pile is not ours and stays put.
    private static let cap = 5

    /// The furthest back a sweep may reach, whatever `grantedAt` says.
    private static let window: TimeInterval = 3600

    /// Cumulative 0s, 10s, 25s, 45s, 75s, 120s. Google's notice lands after the consent, and
    /// Gmail's search index lags the delivery again, so one pass loses both races.
    private static let attemptDelays: [Duration] = [
        .zero, .seconds(10), .seconds(15), .seconds(20), .seconds(30), .seconds(45),
    ]

    /// How many rate refusals to ride out before giving up on the notice entirely.
    private static let maxRefusals = 4

    private static var inFlight = false
    private static var sweeper: Task<Void, Never>?

    /// What one pass came back with. A search Gmail refused is not the same answer as a
    /// search that found nothing, and spending an attempt on it loses a real one.
    enum Pass {
        case archived(Int)
        case empty
        case throttled
    }

    /// Watch for the notice until one is archived or the attempts run out. A fresh consent
    /// restarts the watch, because it is a fresh notice to wait for.
    static func arm() {
        sweeper?.cancel()
        sweeper = Task {
            var attempt = 0
            var refusals = 0
            var wait = attemptDelays[0]
            while attempt < attemptDelays.count {
                if wait != .zero { try? await Task.sleep(for: wait) }
                guard !Task.isCancelled else { return }
                switch await run() {
                case .archived:
                    return
                case .empty:
                    attempt += 1
                    wait = attempt < attemptDelays.count ? attemptDelays[attempt] : .zero
                case .throttled:
                    guard refusals < maxRefusals else {
                        RealtimeLog.log("grantAlerts: gave up after \(refusals) refusals")
                        return
                    }
                    // The shared bucket, so the rest of the phone's Gmail work backs off with
                    // us — the burst that earns this refusal is never the sweep alone.
                    await GmailQuota.shared.penalise(attempt: refusals)
                    refusals += 1
                    wait = .zero
                }
            }
            RealtimeLog.log("grantAlerts: nothing found in \(attemptDelays.count) passes")
        }
    }

    /// One pass. A no-op on a phone holding no Google grant.
    @discardableResult
    static func run() async -> Pass {
        guard !inFlight else { return .empty }
        inFlight = true
        defer { inFlight = false }

        let accounts = GoogleCredential.storedAccounts()
        guard !accounts.isEmpty else {
            RealtimeLog.log("grantAlerts: no Google grant on this phone")
            return .empty
        }

        var archived: [String] = []
        var throttled = false
        for account in accounts {
            let pass = await sweep(account)
            archived += pass.archived
            throttled = throttled || pass.throttled
        }
        RealtimeLog.log("grantAlerts: archived \(archived.count) across \(accounts.count)")
        guard !archived.isEmpty else { return throttled ? .throttled : .empty }

        // Out of the phone's cache as well: the local queue walks that, not Gmail.
        await Container.shared.mailStore().dropUnread(archived)
        return .archived(archived.count)
    }

    private static func sweep(_ account: String) async -> (archived: [String], throttled: Bool) {
        guard let grant = GoogleAccountStore.grant(for: account) else { return ([], false) }
        guard case .success(let token) = await GoogleCredential.token(for: account) else {
            RealtimeLog.log("grantAlerts: no token for \(account)")
            return ([], false)
        }

        let since = max(grant.grantedAt, Date().addingTimeInterval(-window))
        // `after:` takes epoch seconds and honours them to the second, not the day.
        let query = "from:\(sender) in:inbox after:\(Int(since.timeIntervalSince1970))"
        let found: [GmailAPI.MessageRef]
        do {
            found = try await GmailAPI.recentMessageIds(
                token: token.accessToken, query: query, limit: cap)
        } catch GmailAPI.Failure.throttled {
            RealtimeLog.log("grantAlerts: search throttled for \(account)")
            return ([], true)
        } catch {
            RealtimeLog.log("grantAlerts: search failed for \(account) — \(error)")
            return ([], false)
        }
        RealtimeLog.log("grantAlerts: \(found.count) for \(account) since \(since)")

        var archived: [String] = []
        for message in found {
            do {
                try await GmailAPI.archive(token: token.accessToken, id: message.id)
                archived.append(message.id)
            } catch GmailAPI.Failure.throttled {
                RealtimeLog.log("grantAlerts: \(message.id) archive throttled")
                return (archived, true)
            } catch {
                RealtimeLog.log("grantAlerts: \(message.id) not archived — \(error)")
            }
        }
        return (archived, false)
    }
}
