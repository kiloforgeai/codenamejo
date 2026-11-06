import Foundation

struct TurnHistory {
    private var records: [UUID: CommandRecord] = [:]
    private var failedTurns = Set<UUID>()

    mutating func refused(_ origin: LiveHistoryOrigin, attempt: CommandRecord.ToolStep,
                          conversationID: UUID?) -> CommandRecord {
        var record = records[origin.id] ?? CommandRecord(id: origin.id, commandText: origin.userText, conversationId: conversationID)
        if record.toolSteps?.contains(where: { $0.callID == attempt.callID }) != true {
            record.toolSteps = (record.toolSteps ?? []) + [attempt]
        }
        record.status = .failed
        failedTurns.insert(origin.id)
        records[origin.id] = record
        return record
    }

    mutating func feedbackSettled(ids: [String], feedbackID: UUID?, status: CommandRecord.CommandStatus) -> [CommandRecord] {
        ids.compactMap { UUID(uuidString: $0) }.compactMap { id in
            guard var record = records[id] else { return nil }
            record.feedbackID = feedbackID
            record.status = status
            if let feedbackID {
                let call = "feedback-" + feedbackID.uuidString
                record.toolSteps = (record.toolSteps ?? []).filter { $0.callID != call }
                    + [.init(tool: "log_feedback", outcome: "success", callID: call)]
            }
            records[id] = record
            return record
        }
    }

    mutating func cancelUnanswered(id: UUID) -> CommandRecord? {
        guard var record = records[id], record.status == .pending,
              record.responseText.isEmpty, record.toolSteps?.isEmpty != false else { return nil }
        record.status = .cancelled
        records[id] = record
        return record
    }

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
        record = record.preservingTerminalAttempts(from: records[id])
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
        record = record.preservingTerminalAttempts(from: records[record.id])
        records[record.id] = record
        return record
    }

    mutating func complete(_ turn: CommandRecord) -> CommandRecord {
        let previous = records[turn.id]
        var record = turn
        if failedTurns.contains(turn.id) { record.status = .failed }
        // Finalization receives a cumulative span for this turn, not a new segment.
        record.durationSeconds = max(record.durationSeconds, previous?.durationSeconds ?? 0)
        record.issuedAt = previous?.issuedAt ?? turn.issuedAt
        record.toolSteps = turn.toolSteps ?? previous?.toolSteps
        record.latency = turn.latency ?? previous?.latency
        var brainSteps = previous?.brainSteps ?? []
        for step in turn.brainSteps ?? [] {
            if let id = step.responseID, let index = brainSteps.firstIndex(where: { $0.responseID == id }) { brainSteps[index] = step }
            else if !brainSteps.contains(step) { brainSteps.append(step) }
        }
        record.brainSteps = brainSteps.isEmpty ? nil : brainSteps
        record = record.preservingTerminalAttempts(from: previous)
        records[record.id] = record
        return record
    }

    mutating func telemetry(_ entry: TurnTelemetry.Entry, id: UUID, at date: Date) -> CommandRecord? {
        guard var record = records[id] else { return nil }
        record.durationSeconds = max(record.durationSeconds, entry.duration(at: date))
        record.latency = entry.latency ?? record.latency
        record.brainSteps = entry.brainSteps.isEmpty ? record.brainSteps : entry.brainSteps
        records[id] = record
        return record
    }
}

/// Timing belongs to an identified turn within one connection generation. A late response
/// may update that turn, but can never consume the current turn's timer or brain steps.
struct TurnTelemetry {
    struct Entry {
        var started: Date?
        var ended: Date?
        var brainSteps: [CommandRecord.BrainStep] = []
        var latency: TurnLatency?
        var finalizedReply: String?
        func duration(at now: Date) -> TimeInterval { started.map { max(0, (ended ?? now).timeIntervalSince($0)) } ?? 0 }
    }
    private(set) var entries: [UUID: Entry] = [:]
    mutating func begin(_ id: UUID, at date: Date) {
        if entries[id]?.started == nil { entries[id, default: .init()].started = date }
    }
    mutating func end(_ id: UUID, at date: Date) {
        if entries[id]?.ended == nil { entries[id, default: .init()].ended = date }
    }
    mutating func record(_ step: CommandRecord.BrainStep, for id: UUID) {
        var entry = entries[id, default: .init()]
        if let response = step.responseID, let index = entry.brainSteps.firstIndex(where: { $0.responseID == response }) {
            entry.brainSteps[index] = step
        } else if !entry.brainSteps.contains(step) { entry.brainSteps.append(step) }
        entries[id] = entry
    }
    mutating func record(_ latency: TurnLatency, for id: UUID) { entries[id, default: .init()].latency = latency }
    mutating func finish(_ id: UUID, reply: String, at date: Date) {
        guard entries[id]?.finalizedReply != reply else { return }
        entries[id, default: .init()].ended = date
        entries[id, default: .init()].finalizedReply = reply
    }
}

extension CommandRecord.ToolStep {
    init(_ step: TurnStep) {
        self.init(tool: step.tool,
                  milliseconds: step.serverMilliseconds.flatMap { $0 > 0 ? $0 : nil },
                  outcome: step.failed ? "failed" : step.isRunning ? "unknown" : "success")
    }
}
