import Foundation

struct ToolArguments {
    private let source: String
    private let values: [String: Any]?

    init(_ json: String) {
        source = json
        values = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
    }

    func string(_ key: String) -> String? {
        guard let value = values?[key] as? String, !value.isEmpty else { return nil }
        return value
    }

    func integer(_ key: String) -> Int? {
        if let value = values?[key] as? Int { return value }
        if let text = values?[key] as? String { return Int(text) }
        return nil
    }

    func bool(_ key: String) -> Bool? { values?[key] as? Bool }

    var actions: [CommandAction] {
        guard let raw = values?["actions"] as? [[String: Any]] else { return [] }
        return raw.compactMap { step in
            guard let tool = step["tool"] as? String else { return nil }
            return CommandAction(tool: tool, detail: step["detail"] as? String ?? "")
        }
    }

    func replacingString(_ key: String, with value: String) -> String {
        guard var values else { return source }
        values[key] = value
        guard let data = try? JSONSerialization.data(withJSONObject: values) else { return source }
        return String(decoding: data, as: UTF8.self)
    }
}
