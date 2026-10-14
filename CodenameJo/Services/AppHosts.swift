import Foundation

/// The token server this build talks to, from Config/Version.xcconfig (overridable in Local.xcconfig).
enum AppHosts {
    static let tokenServer = Bundle.main.object(forInfoDictionaryKey: "JoTokenServerHost") as? String ?? ""
    /// The GitHub OAuth App's client id (public, no secret), for the device flow. Empty hides GitHub.
    static let githubClientID = (Bundle.main.object(forInfoDictionaryKey: "JoGitHubClientID") as? String ?? "")
        .trimmingCharacters(in: .whitespaces)
}
