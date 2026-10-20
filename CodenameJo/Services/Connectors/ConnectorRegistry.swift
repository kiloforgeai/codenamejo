import Foundation

/// Every connector, as a table like `LiveSessionSetup.tools`: values with no state of their own.
enum ConnectorRegistry {
    /// In skill order. `LivePrompt` concatenates skill text in this order and History lists chips in it,
    /// so a new connector's place here is a prompt decision.
    static let all: [any Connector] = [
        SlackConnector(), NotionConnector(), GranolaConnector(), GitHubConnector(), CustomMCPConnector(),
    ]

    static func owner(of tool: String) -> (any Connector)? { all.first { $0.owns(tool) } }
    static func owns(_ tool: String) -> Bool { owner(of: tool) != nil }

    /// Every connector's standing for the profile, by id, from the Keychain.
    static func statuses(profileId: String?) -> [String: ConnectorStatus] {
        Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0.status(profileId: profileId)) })
    }

    /// The same at dial, renewing what each connector renews.
    static func dialStatuses(profileId: String?) async -> [String: ConnectorStatus] {
        var out: [String: ConnectorStatus] = [:]
        for connector in all { out[connector.id] = await connector.dialStatus(profileId: profileId) }
        return out
    }
}
