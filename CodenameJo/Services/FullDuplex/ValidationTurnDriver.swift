#if DEBUG
import FactoryKit
import Foundation

@MainActor
final class ValidationTurnDriver {
    struct Turn: Decodable {
        let afterOutput: [String]
        let timeout: Double?

        func isValid(at index: Int) -> Bool {
            (timeout ?? 90) > 0 && (timeout ?? 90) <= 180
                && (index == 0 || !afterOutput.isEmpty)
                && afterOutput.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
    }
    private let evidence = Container.shared.voiceEvidence()
    private var task: Task<Void, Never>?
    private var output = ""
    private var input = ""
    private var lastDelta = ProcessInfo.processInfo.systemUptime

    func receive(_ data: Data) {
        guard let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String, let delta = event["delta"] as? String else { return }
        if type == "session.output_transcript.delta", event["client_event_id"] == nil {
            output += delta
            lastDelta = ProcessInfo.processInfo.systemUptime
        } else if type == "session.input_transcript.delta", event["client_event_id"] == nil {
            input += delta
        }
    }

    func start(injector: CaptureInjector, settled: @escaping @MainActor () -> Bool) {
        guard evidence.runID != nil else { return }
        stop()
        let raw = ProcessInfo.processInfo.environment["VALIDATION_TURNS"] ?? ""
        guard let data = raw.data(using: .utf8), let turns = try? JSONDecoder().decode([Turn].self, from: data),
              turns.count == CaptureInjector.fixtureNames.count,
              !turns.isEmpty, turns.enumerated().allSatisfy({ $0.element.isValid(at: $0.offset) }) else {
            evidence.record("scenario.failed", ["reason": "invalid validation turns"])
            return
        }
        output = ""
        input = ""
        task = Task { [weak self] in
            guard let self else { return }
            var next = 0
            var reportedStarted = 0
            var reportedFinished = 0
            var initializedRate = 0
            var deadline = ProcessInfo.processInfo.systemUptime + (turns[0].timeout ?? 90)
            while !Task.isCancelled {
                let now = ProcessInfo.processInfo.systemUptime
                let status = injector.validationStatus
                if initializedRate != status.rate, status.rate > 0 {
                    initializedRate = status.rate
                    evidence.record("capture.initialized", ["sampleRate": status.rate])
                }
                if status.started > reportedStarted {
                    evidence.record("clip.started", ["index": status.started - 1])
                    reportedStarted = status.started
                }
                if status.finished > reportedFinished {
                    evidence.record("clip.finished", ["index": status.finished - 1])
                    reportedFinished = status.finished
                }
                if status.failed {
                    evidence.record("scenario.failed", ["reason": "missing or invalid WAV"])
                    return
                }
                let quiet = status.lastAudio == 0 || Double(DispatchTime.now().uptimeNanoseconds - status.lastAudio) / 1e9 >= 1
                if next < turns.count, initializedRate > 0, status.finished >= next, settled(), quiet,
                   now - lastDelta >= 1, (next == 0 || !input.isEmpty),
                   turns[next].afterOutput.allSatisfy({ self.output.localizedCaseInsensitiveContains($0) }) {
                    if next > 0 {
                        evidence.record("turn.completed", ["index": next - 1, "input": input, "output": output])
                    }
                    evidence.record("clip.released", ["index": next, "afterOutput": turns[next].afterOutput])
                    next += 1
                    injector.releaseValidationClip(next)
                    output = ""
                    input = ""
                    deadline = now + (next < turns.count ? turns[next].timeout ?? 90 : turns[next - 1].timeout ?? 90)
                }
                if next == turns.count, status.finished == turns.count, !input.isEmpty, !output.isEmpty,
                   settled(), quiet, now - lastDelta >= 1 {
                    evidence.record("turn.completed", ["index": next - 1, "input": input, "output": output])
                    evidence.record("scenario.turnsCompleted")
                    return
                }
                if now >= deadline {
                    evidence.record("scenario.failed", ["reason": "turn conditions timed out", "next": next,
                        "settled": settled(), "quiet": quiet, "input": input, "output": output])
                    return
                }
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
        }
    }

    func stop() { task?.cancel(); task = nil }
}
#endif
