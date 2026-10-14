import FactoryKit
import Foundation

/// The ranked Slack queue the phone walks: up to ten unread conversations with their messages
/// already in hand, so every step after the sweep is a memory read.
struct SlackQueueSnapshot: Codable, Sendable {
    struct Message: Codable, Sendable, Equatable {
        let from: String
        let fromId: String?
        let ts: String
        let text: String
        let threadTs: String?
        let replies: Int?
    }

    struct Item: Codable, Sendable {
        let teamId: String
        let teamName: String
        let channelId: String
        let withUserId: String?
        let label: String
        let kind: String
        let unread: Int
        let more: Bool
        let messages: [Message]
        let why: String
        /// High is walked between the important mail and the rest; never spoken.
        var band: String? = nil
        var acted: String?
        var markedRead: Bool?
    }

    struct Report: Codable, Sendable {
        let workspacesUnavailable: [String]?
        let unchecked: Int
        let unreachable: Int
        let readStateUnknown: Int
        let dmsUnavailable: Bool?
        let markUnavailable: Bool?
    }

    let workspaces: [String]
    let total: Int
    var items: [Item]
    let report: Report

    static let empty = SlackQueueSnapshot(
        workspaces: [], total: 0, items: [],
        report: .init(workspacesUnavailable: nil, unchecked: 0, unreachable: 0, readStateUnknown: 0,
                      dmsUnavailable: nil, markUnavailable: nil))
}

/// The last sweep per profile, in memory only: a queue is rebuilt from Slack whenever it is
/// older than `LocalSlackQueue.servingFreshness`, so nothing about it needs to survive a launch.
actor SlackQueueCache {
    struct Loaded: Sendable {
        let generatedAt: Date
        let teams: [String]
        let queue: SlackQueueSnapshot?
    }

    private var entries: [String: Loaded] = [:]

    func load(_ key: String) -> Loaded? { entries[key] }
    func save(_ key: String, _ loaded: Loaded) { entries[key] = loaded }
    func purgeAll() { entries = [:] }
}

/// Builds the queue from Slack into `SlackQueueCache`.
enum SlackQueueRefresh {
    /// A Feed prefetch reuses a sweep younger than this.
    static let backgroundFreshness: TimeInterval = 5 * 60

    /// The key a sweep is cached under. The default profile is `""`.
    static func profileKey(_ scope: ProfileRuntime.Scope? = ProfileRuntime.snapshot) -> String {
        guard let scope, !scope.isDefault else { return "" }
        return scope.profileId
    }

    static func cached(scope: ProfileRuntime.Scope? = ProfileRuntime.snapshot) async -> SlackQueueCache.Loaded? {
        await Container.shared.slackQueueCache().load(profileKey(scope))
    }

    static func forFeed(scope: ProfileRuntime.Scope?) async -> SlackQueueCache.Loaded? {
        if let stored = await cached(scope: scope),
           Date().timeIntervalSince(stored.generatedAt) < backgroundFreshness { return stored }
        return await fetch(trigger: "feed", scope: scope)
    }

    /// Sweep now and cache the result. Nil when no workspace is connected in this profile.
    @discardableResult
    static func fetch(trigger: String, scope: ProfileRuntime.Scope? = ProfileRuntime.snapshot) async -> SlackQueueCache.Loaded? {
        let workspaces = SlackWorkspace.served(profileId: scope?.profileId)
        guard !workspaces.isEmpty else { return nil }
        let started = Date()
        let queue = await SlackSweep.buildQueue(workspaces, model: MailImportance.openAI)
        let loaded = SlackQueueCache.Loaded(generatedAt: Date(), teams: workspaces.map(\.teamId), queue: queue)
        await Container.shared.slackQueueCache().save(profileKey(scope), loaded)
        let high = queue.items.filter { $0.band == "high" }.count
        RealtimeLog.log("slackQueue: swept (\(trigger)) — \(queue.items.count) queued of \(queue.total), "
            + "\(high) high, across \(workspaces.count) workspace(s) in \(Int(Date().timeIntervalSince(started) * 1000))ms")
        return loaded
    }
}

/// The Feed's Slack stage runs once per local day per workspace, like the calendar's.
enum SlackFeedCadence {
    static func owners(teams: [String]) -> [String] { teams.map { "slack:\($0)" } }
}
