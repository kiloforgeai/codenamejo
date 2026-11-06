import FactoryKit
import Foundation

enum TaskManagementTool {
    static let schema: [String: Any] = [
        "type": "function", "name": "manage_task",
        "description": "Inspect, select, correct or cancel an existing background task. Never retarget from the foreground email. Use for the user's explicit task follow-up; list first if the task is unknown. browser shows the existing browser, or opens the original website for inspection if the browser expired. It never proves whether a previous submission occurred. For open/view/click-the-link/fill requests, perform browser now, not another offer. restart_browser rebuilds a verified unsubmitted task and needs fresh page-bound approval; an unavailable legacy outcome first needs inspection and explicit verification. resume_browser continues the same live task; pass its exact approval_id and revision only after explicit approval. Never redispatch to repeat a submission or infer approval from viewing. Unknown or committed outcomes permit inspection only. For website invitations use the source email's actual link/provider, not an assumed Google Calendar event. completion_preference changes reporting only: quiet or bring_back. This tool does not approve an email send.",
        "parameters": ["type": "object", "properties": [
            "action": ["type": "string", "enum": ["list", "select", "browser", "resume_browser", "restart_browser", "correct", "choose", "resume_archive", "cancel", "completion_preference"]],
            "reference": ["type": "string", "description": "Exact listed task ID, unique ID prefix or request. Omit only for the visibly selected task."],
            "revision": ["type": "integer"], "instruction": ["type": "string"],
            "approval_id": ["type": "string", "description": "Exact current browser approval ID, only after the user explicitly approves that form action."],
            "choice": ["type": "string", "description": "Exact candidate ID the user selected from this task's choices. This resumes the same task and reads only; never submits an RSVP."],
            "preference": ["type": "string", "enum": ["quiet", "bring_back"]]
        ], "required": ["action"], "additionalProperties": false]
    ]

    @MainActor
    static func run(_ json: String, userRequest: String? = nil) async -> (String, Bool) {
        let args = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
        let tasks = Container.shared.applicationTasks(), store = Container.shared.dispatchJobs()
        let action = args["action"] as? String ?? "list"
        if action == "list" {
            let rows = await store.history()
            return (GmailReadTools.json(["tasks": rows.prefix(20).map { ["id": $0.id.uuidString,
                "revision": $0.taskRevision, "task": $0.task, "state": $0.state,
                "account": $0.origin?.account ?? "", "message_id": $0.origin?.messageID ?? "",
                "deferred_archive": $0.context?.deferredFeedbackArchive == true, "browser": browserContext($0),
                "choices": ($0.inputChoices ?? []).map { ["id": $0.id, "label": $0.label] }] as [String: Any] }]), false)
        }
        do {
            let job = try await tasks.resolve(args["reference"] as? String)
            if action == "select" || action == "browser" {
                if action == "browser", job.browserState == nil {
                    _ = await store.recordBrowserState(job.id, state: .unavailable)
                }
                tasks.select(job.id)
                #if targetEnvironment(macCatalyst)
                if action == "browser" { try await tasks.inspectBrowser(job.id, version: job.taskRevision) }
                #endif
                var context = tasks.selectedContext
                context["presentation"] = "This task is selected in the center pane. Availability live or inspection means a browser exists; inspection never establishes past submission status or authorizes filling/submitting. Explain the exact remaining blocker once. Selecting never submits or records approval."
                context["browser"] = browserContext(job)
                #if targetEnvironment(macCatalyst)
                let browsers = Container.shared.backgroundBrowsers()
                if action == "browser", browsers.availability(job) != "live" {
                    context["result"] = browsers.recoveryNotice(job)
                }
                #endif
                return (GmailReadTools.json(context), false)
            }
            guard let version = args["revision"] as? Int else { throw DispatchWorker.StepFailure(message: "Inspect this task's current revision before changing it.") }
            if action == "restart_browser" {
                #if targetEnvironment(macCatalyst)
                let request = FullDuplexVoiceClient.normalize(userRequest ?? "")
                let decision = request.replacingOccurrences(of: #"\b(?:nothing was submitted|not submitted|wasn t submitted)\b"#,
                    with: "", options: .regularExpression)
                guard requestsBrowser(request),
                      decision.range(of: #"\b(?:don t|do not|dont|not|cancel|wait|hold off|stop|never|whether|maybe|should)\b"#,
                        options: .regularExpression) == nil else {
                    throw DispatchWorker.StepFailure(message: "Rebuilding needs an explicit open or fill request. Viewing the website with browser remains available; approval of an old form cannot authorize submission.")
                }
                if job.browserState != .unsubmitted,
                   !["nothing was submitted", "not submitted", "wasn t submitted"].contains(where: request.contains) {
                    try await tasks.inspectBrowser(job.id, version: version)
                    return (GmailReadTools.json(["browser": browserContext(job),
                        "remaining_step": "Check the original site's registration status. Before rebuilding this legacy task, explicitly verify that it was not submitted. No previous outcome is established by opening the page."]), false)
                }
                try await tasks.restartBrowser(job.id, version: version,
                    verifiedUnsubmitted: ["nothing was submitted", "not submitted", "wasn t submitted"].contains(where: request.contains))
                #else
                throw DispatchWorker.StepFailure(message: "Browser recovery is available in the Mac app.")
                #endif
            }
            else if action == "resume_browser" {
                #if targetEnvironment(macCatalyst)
                let selected = tasks.selectedTaskID
                tasks.select(job.id)
                let approval = (args["approval_id"] as? String).flatMap(UUID.init(uuidString:))
                if args["approval_id"] != nil {
                    guard let approval, approvesBrowser(userRequest ?? "") else {
                        throw DispatchWorker.StepFailure(message: "Approval needs a current form and an explicit request to submit it, or its exact Approve button. Nothing was submitted.")
                    }
                    let pending = Container.shared.backgroundBrowsers().sessions.values.filter { $0.current() && $0.phase == .approval }
                    guard pending.count <= 1 || selected == job.id else {
                        throw DispatchWorker.StepFailure(message: "More than one form needs approval. Select the intended form first; nothing was submitted.")
                    }
                    try await tasks.resumeBrowser(job.id, version: version, approval: approval)
                } else { try await tasks.resumeBrowser(job.id, version: version) }
                #else
                throw DispatchWorker.StepFailure(message: "Browser continuation is available in the Mac app.")
                #endif
            }
            else if action == "cancel" { try await tasks.cancel(job.id, version: version) }
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

    @MainActor
    static func browserContext(_ job: DispatchJob) -> [String: Any] {
        #if targetEnvironment(macCatalyst)
        let browsers = Container.shared.backgroundBrowsers()
        let availability = browsers.availability(job)
        guard let browser = browsers.sessions[job.id], browser.current(), browser.webView != nil else {
            return ["availability": availability, "task_id": job.id.uuidString, "task_revision": job.taskRevision,
                "notice": browsers.recoveryNotice(job), "approval_valid": false,
                "recovery_action": "browser",
                "rule": "Use browser to inspect the original website before asking whether to rebuild it. An unavailable browser does not prove that nothing was submitted. Unknown or committed actions cannot replay."]
        }
        var value: [String: Any] = ["task_id": job.id.uuidString, "task_revision": job.taskRevision,
            "availability": availability,
            "inspection_only": browser.inspectionOnly,
            "phase": browser.phase.rawValue, "notice": browser.message,
            "control_owner": browser.webView?.isUserInteractionEnabled == true ? "user" : "jo",
            "rule": "Use this same task for viewing. An inspection browser permits checking the site, not refilling or submission. Its existence does not establish any past outcome. State the exact verification needed before restart_browser; never repeatedly offer to open an already requested page."]
        if let approval = browser.approval, browser.phase == .approval {
            value["approval_id"] = approval.id.uuidString
            value["action"] = approval.label
            value["expected_receipt"] = approval.receipt
            value["page_revision"] = approval.revision
        }
        return value
        #else
        return [:]
        #endif
    }

    static func approvesBrowser(_ request: String) -> Bool {
        let text = FullDuplexVoiceClient.normalize(request)
        guard text.range(of: #"\b(?:don t|do not|dont|not|cancel|wait|hold off|stop|never|whether|maybe|should we)\b"#,
                         options: .regularExpression) == nil else { return false }
        return text.range(of: #"\b(?:submit|approve|send it|go ahead)\b"#, options: .regularExpression) != nil
    }

    static func requestsBrowser(_ request: String) -> Bool {
        FullDuplexVoiceClient.normalize(request).range(of: #"\b(?:restart|reopen|rebuild|start over|open|view|inspect|click|fill)\b"#,
            options: .regularExpression) != nil
    }
}
