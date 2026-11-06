#if targetEnvironment(macCatalyst) && (JO_QA || JO_TESTING)
#if JO_TESTING
@testable import CodenameJo
#endif
import Foundation

@MainActor
class BackgroundBrowserFixture {
    let server = BrowserHTTPFixture()
    var base: URL?

    func respond(_ body: [String: Any]) async throws -> [[String: Any]] {
        if base == nil { base = try await server.start() }
        let input = body["input"] as? [[String: Any]] ?? []
        let request = input.first?["content"] as? String ?? ""
        let output = input.last(where: { $0["type"] as? String == "function_call_output" })?["output"] as? String
        let snapshot = output.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        let text = snapshot?["text"] as? String ?? ""
        if text.contains("Request received;") || text.contains("Tuesday 10 am") {
            let report = GmailReadTools.json(["status": "completed", "report": text,
                "completed": true, "remaining_work": "none", "report_back": !request.contains("quiet")])
            return [["type": "message", "content": [["type": "output_text", "text": report]]]]
        }
        var args: [String: Any]
        if let snapshot {
            let controls = snapshot["controls"] as? [[String: String]] ?? []
            let form = request.contains("browser form fixture")
            let filled = input.contains { ($0["arguments"] as? String)?.contains("Guest fixture") == true }
            let label = form ? (filled ? "Request place" : "Guest name") : "See times"
            guard let control = controls.first(where: { $0["label"] == label }), let revision = snapshot["revision"] as? String else {
                throw BackgroundBrowser.Failure(message: "Controlled fixture did not expose its expected control.")
            }
            args = ["action": form && !filled ? "fill" : "click", "control_id": control["id"]!, "revision": revision,
                "value": "Guest fixture", "expected_receipt": "Request received; host approval pending."]
        } else if request.contains("User correction") {
            args = ["action": "inspect"]
        } else {
            args = ["action": "open", "url": base!.appendingPathComponent("event").absoluteString + "?" + UUID().uuidString]
        }
        return [["type": "function_call", "name": BackgroundBrowserStore.toolName,
            "call_id": UUID().uuidString, "arguments": GmailReadTools.json(args)]]
    }
}
#endif
