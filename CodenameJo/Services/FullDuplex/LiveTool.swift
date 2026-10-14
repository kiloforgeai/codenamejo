import Foundation

/// One function call from the Live session, as `FullDuplexVoiceClient.runFunctionTool` received it.
struct LiveToolCall {
    let id: String
    let name: String
    let arguments: String
    /// The adapter heard the user ask for background work; only `dispatch` reads it.
    var requestedBackground = false
}

/// A function tool of the Live session: the schema the model is given and what a call to it runs.
/// `LiveSessionSetup.tools` holds every one by name, and the session's tool list is built from it.
protocol LiveTool {
    var name: String { get }
    /// The definition for this session's accounts. Nil for a name still answered but no longer declared.
    func schema(_ accounts: LiveSessionSetup.Accounts) -> [String: Any]?
    /// Every handler posts its own function output.
    @MainActor func run(_ call: LiveToolCall, on client: FullDuplexVoiceClient)
}

/// Answered on this phone by one of the voice client's handlers.
struct PhoneTool: LiveTool {
    let name: String
    private let definition: ((LiveSessionSetup.Accounts) -> [String: Any])?
    private let handler: @MainActor (FullDuplexVoiceClient, LiveToolCall) -> Void

    init(_ schema: [String: Any], run: @escaping @MainActor (FullDuplexVoiceClient, LiveToolCall) -> Void) {
        self.init(schema["name"] as? String ?? "", { _ in schema }, run: run)
    }

    init(_ name: String, _ schema: ((LiveSessionSetup.Accounts) -> [String: Any])?,
         run: @escaping @MainActor (FullDuplexVoiceClient, LiveToolCall) -> Void) {
        self.name = name
        definition = schema
        handler = run
    }

    func schema(_ accounts: LiveSessionSetup.Accounts) -> [String: Any]? { definition?(accounts) }

    @MainActor func run(_ call: LiveToolCall, on client: FullDuplexVoiceClient) { handler(client, call) }
}

/// A connector's tool, run by `FullDuplexBroker.runTool` the way any name without an entry is.
struct ConnectorTool: LiveTool {
    let name: String
    private let definition: [String: Any]

    init(_ schema: [String: Any]) {
        name = schema["name"] as? String ?? ""
        definition = schema
    }

    func schema(_ accounts: LiveSessionSetup.Accounts) -> [String: Any]? { definition }

    @MainActor func run(_ call: LiveToolCall, on client: FullDuplexVoiceClient) { client.runUnregisteredTool(call) }
}
