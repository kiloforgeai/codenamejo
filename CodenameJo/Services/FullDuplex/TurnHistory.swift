import Foundation

struct TurnHistory {
    private var records: [UUID: CommandRecord] = [:]
    private var failedTurns = Set<UUID>()

    mutating func fail(id: UUID, text: String, conversationID: UUID?, steps: [TurnStep]) -> CommandRecord? {
        guard var record = checkpoint(id: id, text: text, conversationID: conversationID, steps: steps) ?? records[id] else { return nil }
        failedTurns.insert(id)
        record.status = .failed
        records[id] = record
        return record
    }

    mutating func checkpoint(id: UUID, text: String, conversationID: UUID?, steps: [TurnStep]) -> CommandRecord? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var record = records[id] ?? CommandRecord(id: id, commandText: text, conversationId: conversationID)
        record.commandText = text
        if !steps.isEmpty {
            record.status = CommandRecord.outcome(steps: steps, interrupted: false)
            record.toolSteps = steps.map(CommandRecord.ToolStep.init)
        }
        if failedTurns.contains(id) { record.status = .failed }
        guard record != records[id] else { return nil }
        records[id] = record
        return record
    }

    mutating func reply(_ reply: LiveHistoryReply, conversationID: UUID?,
                        status: CommandRecord.CommandStatus?) -> CommandRecord {
        var record = records[reply.origin.id] ?? CommandRecord(
            id: reply.origin.id, commandText: reply.origin.userText, conversationId: conversationID)
        record.responseText = SpokenAddress.written(reply.text)
        record.status = status ?? record.status
        record.toolSteps = record.toolSteps?.map { step in
            var step = step
            if step.tool == "dispatch" { step.outcome = record.status.rawValue }
            return step
        }
        records[record.id] = record
        return record
    }

    mutating func complete(_ turn: CommandRecord) -> CommandRecord {
        let previous = records[turn.id]
        var record = turn
        if failedTurns.contains(turn.id) { record.status = .failed }
        record.durationSeconds += previous?.durationSeconds ?? 0
        record.issuedAt = previous?.issuedAt ?? turn.issuedAt
        record.toolSteps = turn.toolSteps ?? previous?.toolSteps
        record.latency = turn.latency ?? previous?.latency
        let brainSteps = (previous?.brainSteps ?? []) + (turn.brainSteps ?? [])
        record.brainSteps = brainSteps.isEmpty ? nil : brainSteps
        records[record.id] = record
        return record
    }
}

extension CommandRecord.ToolStep {
    init(_ step: TurnStep) {
        self.init(tool: step.tool,
                  milliseconds: step.serverMilliseconds.flatMap { $0 > 0 ? $0 : nil },
                  outcome: step.failed ? "failed" : step.isRunning ? "unknown" : "success")
    }
}
