import Foundation

/// One remote MCP server this phone signs in to and calls itself, over streamable HTTP. It is
/// never attached to the OpenAI session, so its tokens stay on the phone.
struct RemoteMCPService: Sendable, Equatable, Hashable {
    /// Namespaces the Keychain items, and names the service in logs. Never change it once shipped:
    /// a new id orphans every stored grant.
    let id: String
    let displayName: String
    /// The streamable-HTTP endpoint, e.g. `https://mcp.notion.com/mcp`.
    let endpoint: URL
    /// Sent as `scope` on the authorize call when the server advertises one.
    var scope: String? = nil
    var clientName = "Codename Jo"

    /// The redirect registered with every server. `ASWebAuthenticationSession` intercepts it, so it
    /// needs no `CFBundleURLTypes` entry.
    static let redirectURI = "com.kiloforge.codenamejo:/oauth/callback"
    static let callbackScheme = "com.kiloforge.codenamejo"
}
