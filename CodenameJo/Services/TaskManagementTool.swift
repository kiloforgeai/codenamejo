import FactoryKit
import Foundation

enum TaskManagementTool {
    static let schema: [String: Any] = [
        "type": "function", "name": "manage_task",
        "description": "Inspect, select, correct or cancel an existing background task. Never retarget it from the foreground email. Use only for the user's explicit task follow-up, never for stop speaking. List first for a reference not already known; pass the listed revision for mutations. If ambiguous, present the returned choices once. Corrections preserve source/scope and refuse replay of committed or uncertain actions. completion_preference changes reporting only, without rerunning or approving work. Use quiet for no need to tell me when it succeeds; bring_back for bring me the result when ready. This tool does not approve a send.",
        "parameters": ["type": "object", "properties": [
            "action": ["type": "string", "enum": ["list", "select", "correct", "choose", "resume_archive", "cancel", "completion_preference"]],
            "reference": ["type": "string", "description": "Exact listed task ID, unique ID prefix or request. Omit only for the visibly selected task."],
            "revision": ["type": "integer"], "instruction": ["type": "string"],
            "choice": ["type": "string", "description": "Exact candidate ID the user selected from this task's choices. This resumes the same task and reads only; never submits an RSVP."],
            "preference": ["type": "string", "enum": ["quiet", "bring_back"]]
        ], "required": ["action"], "additionalProperties": false]
    ]

    @MainActor
    static func run(_ json: String) async -> (String, Bool) {
        let args = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
        let tasks = Container.shared.applicationTasks(), store = Container.shared.dispatchJobs()
        let action = args["action"] as? String ?? "list"
        if action == "list" {
            let rows = await store.history()
            return (GmailReadTools.json(["tasks": rows.prefix(20).map { ["id": $0.id.uuidString,
                "revision": $0.taskRevision, "task": $0.task, "state": $0.state,
                "account": $0.origin?.account ?? "", "message_id": $0.origin?.messageID ?? "",
                "deferred_archive": $0.context?.deferredFeedbackArchive == true,
                "choices": ($0.inputChoices ?? []).map { ["id": $0.id, "label": $0.label] }] as [String: Any] }]), false)
        }
        do {
            let job = try await tasks.resolve(args["reference"] as? String)
            if action == "select" { tasks.select(job.id); return (GmailReadTools.json(tasks.selectedContext), false) }
            guard let version = args["revision"] as? Int else { throw DispatchWorker.StepFailure(message: "Inspect this task's current revision before changing it.") }
            if action == "cancel" { try await tasks.cancel(job.id, version: version) }
            else if action == "resume_archive" { try await tasks.resumeFeedbackArchive(job.id, version: version) }
            else if action == "choose" { try await tasks.choose(job.id, version: version, choice: args["choice"] as? String ?? "") }
            else if action == "correct" { try await tasks.correct(job.id, version: version, instruction: args["instruction"] as? String ?? "") }
            else if action == "completion_preference", let value = args["preference"] as? String,
                    let preference = DispatchJob.CompletionPreference(rawValue: value) {
                try await tasks.setPreference(job.id, version: version, preference: preference)
            }
            else { throw DispatchWorker.StepFailure(message: "Unknown task action. Nothing changed.") }
            let current = store.existing(job.id)
            return (GmailReadTools.json(["task_id": job.id.uuidString, "revision": current?.taskRevision ?? version,
                "state": current?.state ?? "unavailable", "result": current?.result ?? ""]), false)
        } catch { return (error.localizedDescription, true) }
    }
}
