import Foundation

enum LocalQueueMCPWritePolicy {
    static let calendarReceiptInstructions = """
        The immediately preceding calendar write result is authoritative. Confirm the completed
        creation or rescheduling in one short sentence, using its title and time when useful. End
        immediately after that confirmation. Ask no question and do not refer to the email or
        queue. Do not call any tool; the client will present the next email separately.
        """

    static func finishesCurrentMessage(_ canonicalTool: String, output: String?) -> Bool {
        let prefix: String
        switch canonicalTool {
        case "create_calendar_event": prefix = "Created \""
        case "update_calendar_event": prefix = "Updated \""
        default: return false
        }
        return output?.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(prefix) == true
    }

    static func receiptInstructions(
        _ canonicalTool: String, output: String?, hasStandingMessage: Bool
    ) -> String? {
        guard hasStandingMessage, finishesCurrentMessage(canonicalTool, output: output) else {
            return nil
        }
        return calendarReceiptInstructions
    }

    static func advancesPastReceiptQuestion(_ canonicalTool: String) -> Bool {
        canonicalTool == "create_calendar_event" || canonicalTool == "update_calendar_event"
    }
}
