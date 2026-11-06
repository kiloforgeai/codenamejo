import Combine
import FactoryKit
import Foundation

/// Owns accepted work independently of the conversation that requested it.
@MainActor
class ApplicationTasks: ObservableObject {
    @Published var revision = 0
    @Published var selectedTaskID: UUID?
    private var editing = Set<UUID>()
    @Injected(\.backend) private var backend
    @Injected(\.dispatchJobs) private var store
    private struct Pending {
        let id: UUID
        let target: String
        let run: () async -> Result
    }
    enum Result {
        case task(FullDuplexBroker.DispatchOutcome)
        case tool(FullDuplexBroker.ToolResult)
        var text: String {
            switch self { case .task(let result): result.text; case .tool(let result): result.text }
        }
    }
    private var pending: [Pending] = []
    private var running: [UUID: Task<Void, Never>] = [:]
    private var targets: [UUID: String] = [:]
    private var results: [UUID: Result] = [:]
    private var waiters: [UUID: [CheckedContinuation<Result, Never>]] = [:]
    private var accepted = Set<UUID>()
    private var operationIDs: [String: UUID] = [:]
    private var storeChanges: AnyCancellable?
    var request: DispatchWorker.Request?
    let capacity: Int

    init(capacity: Int = 3, request: DispatchWorker.Request? = nil) {
        self.capacity = max(1, capacity)
        self.request = request
        storeChanges = store.$changes.dropFirst().sink { [weak self] _ in self?.revision += 1 }
    }

    func refusal(owner: String?, profile: String?, origin: DispatchJob.MailOrigin?) -> String? {
        guard let owner, owner == backend.userId, profile == ProfileRuntime.snapshot?.profileId else {
            return "The account or profile changed. Select the item again before starting work."
        }
        if let origin, !GoogleAccountStore.mailAccounts().contains(where: {
            $0.caseInsensitiveCompare(origin.account) == .orderedSame
        }) { return "The source account is no longer connected in this profile." }
        return nil
    }

    @discardableResult
    func submit(_ source: DispatchWorker.Job) async -> UUID {
        let id = source.id
        guard accepted.insert(id).inserted else { return id }
        if store.contains(id) {
            let saved = store.existing(id)
            results[id] = .task(.init(text: saved?.result ?? "This task already exists. Its outcome must be checked before restarting it.",
                ok: saved?.isDone == true ? true : false, reportBack: saved?.reportBack ?? true,
                status: saved?.isDone == true ? .success : .unknown))
            return id
        }
        let owner = source.ownerID ?? backend.userId
        let origin = source.scope == .independent ? nil : DispatchJob.MailOrigin.captured(in: source.standingOnJSON)
        if (source.scope == .currentEmail || source.holdsDecision == true), origin == nil {
            source.diagnostics?.record(.turnTransition, ["transition": "dispatch_source_refused", "reason": "missing_committed_source", "job_id": id.uuidString])
            results[id] = .task(.init(text: "Not started: this task needs its original selected email. Select that email before retrying; no task or external action was started.", ok: false, status: .failed))
            return id
        }
        if let origin, let account = source.account, !account.isEmpty,
           account.caseInsensitiveCompare(origin.account) != .orderedSame {
            results[id] = .task(.init(text: "Not started: the task account does not match its captured email. Select the original email before retrying.", ok: false, status: .failed))
            return id
        }
        if let origin, source.task.range(of: #"\b(?:link|url|rsvp|event time)\b"#, options: [.regularExpression, .caseInsensitive]) != nil,
           let pending = await store.history().first(where: { $0.sourceSelection == MailSelection(account: origin.account, messageID: origin.messageID)
               && $0.state == "awaiting_input" && $0.inputChoices?.isEmpty == false }) {
            select(pending.id)
            results[id] = .task(.init(text: "Task \(pending.id.uuidString) revision \(pending.taskRevision) already needs a page choice. Use manage_task choose or correct to continue that task; do not dispatch another lookup. " + (pending.result ?? ""), ok: false, status: .pending))
            return id
        }
        if let reason = refusal(owner: owner, profile: source.profileId, origin: origin) {
            results[id] = .task(.init(text: reason, ok: false, status: .failed))
            return id
        }
        await store.begin(id: id, task: source.task, profileId: source.profileId,
            conversationId: source.diagnostics?.conversationID, turnId: source.turnID,
            operation: source.operation, origin: origin, command: source.command)
        let context = DispatchJob.TaskContext(scope: source.scope?.rawValue ?? "current_email",
            expects: source.expects?.rawValue ?? "answer", facts: source.facts,
            authoredAt: source.authoredAt ?? Date(), timeZone: (source.authoredTimeZone ?? .current).identifier,
            input: source.inputSource, parksSource: origin != nil && source.scope != .independent
                && (source.parksSource ?? (source.expects != .receipt)),
            holdsDecision: source.holdsDecision, dependencyID: source.dependencyID, userRequest: source.userRequest)
        guard await store.acceptContext(id, context: context, preference: source.completionPreference ?? .requested(in: source.task)) else {
            results[id] = .task(.init(text: store.persistenceError ?? "Task could not be saved.", ok: false, status: .failed))
            await store.finish(id, state: "failed", result: store.persistenceError ?? "Task could not be saved.")
            revision += 1
            return id
        }
        schedule(source, owner: owner, origin: origin, version: 1)
        return id
    }

    private func schedule(_ source: DispatchWorker.Job, owner: String?, origin: DispatchJob.MailOrigin?, version: Int) {
        let id = source.id
        enqueue(id: id, owner: owner, profile: source.profileId, origin: origin) { [self] in
            var job = source
            job.revision = version
            job.validate = { [weak self] in
                guard let self else { return "Task service is unavailable." }
                guard self.store.matches(id, revision: version) else { return "This task revision has been superseded." }
                return self.refusal(owner: owner, profile: source.profileId, origin: origin)
            }
            if let reason = job.validate?() {
                await store.finish(id, state: "failed", result: reason, revision: version)
                return .task(.init(text: reason, ok: false, status: .failed))
            }
            let outcome = await HangUpRunway.run("Finishing a task", subtitle: "Work continues with voice off.", progress: job.progress) {
                await DispatchWorker.run(job, request: self.request)
            }
            guard store.matches(id, revision: version), let saved = store.existing(id) else {
                return .task(.init(text: "This result belongs to an earlier task or profile.", ok: false, reportBack: false, status: .cancelled))
            }
            return .task(.init(text: saved.result ?? outcome.text, ok: outcome.ok,
                reportBack: saved.state == "cancelled" ? false : saved.reportBack ?? outcome.reportBack, status: outcome.status))
        }
    }

    func select(_ id: UUID?) {
        selectedTaskID = id.flatMap { store.existing($0) == nil ? nil : $0 }
    }

    func deferFeedbackArchive(id: UUID, owner: String?, profile: String?, origin: DispatchJob.MailOrigin,
                              conversation: UUID?) async throws {
        if let reason = refusal(owner: owner, profile: profile, origin: origin) { throw DispatchWorker.StepFailure(message: reason) }
        if store.contains(id) { return }
        let operation = DispatchMailOperation.archiveRequest("archive it", account: origin.account, messageID: origin.messageID)
        await store.begin(id: id, task: "Archive the saved email after feedback", profileId: profile,
            conversationId: conversation, turnId: id.uuidString, operation: operation, origin: origin)
        let context = DispatchJob.TaskContext(scope: "current_email", expects: "receipt", authoredAt: Date(),
            timeZone: TimeZone.current.identifier, input: "voice", parksSource: false, deferredFeedbackArchive: true)
        guard await store.acceptContext(id, context: context, preference: .bringBack) else {
            throw DispatchWorker.StepFailure(message: store.persistenceError ?? "The archive request could not be saved.")
        }
        await store.finish(id, state: "awaiting_input", result: "Archive requested before feedback. Nothing has been archived. Resume this saved action or cancel it in Activities.", historyStatus: .pending)
        if let error = store.persistenceError { throw DispatchWorker.StepFailure(message: error) }
        revision += 1
    }

    func resumeFeedbackArchive(_ id: UUID, version: Int) async throws {
        let job = try authorized(id, version: version)
        guard job.state == "awaiting_input", job.context?.deferredFeedbackArchive == true,
              !job.hasCommittedWrites, let operation = job.operation, let origin = job.origin else {
            throw DispatchWorker.StepFailure(message: "This saved archive is no longer pending. Check its existing receipt; no action was repeated.")
        }
        guard editing.insert(id).inserted else { throw DispatchWorker.StepFailure(message: "This action is already being resumed.") }
        defer { editing.remove(id) }
        guard await store.revise(id, revision: version, task: job.task) else {
            throw DispatchWorker.StepFailure(message: store.persistenceError ?? "The pending action changed.")
        }
        results[id] = nil
        let source = GmailReadTools.json(["account": origin.account, "id": origin.messageID,
            "threadId": origin.threadID, "from": origin.sender, "subject": origin.subject])
        schedule(.init(id: id, task: job.task, account: origin.account, standingOnJSON: source,
            expects: .receipt, scope: .currentEmail, profileId: job.profileId, turnID: job.turnId,
            operation: operation, inputSource: "saved_action", completionPreference: .bringBack, ownerID: job.userId),
            owner: job.userId, origin: origin, version: version + 1)
    }

    var selectedContext: [String: Any] {
        guard let selectedTaskID, let job = store.existing(selectedTaskID) else { return [:] }
        var currentResult = job.result ?? "No result recorded yet."
        #if targetEnvironment(macCatalyst)
        if job.browserState != nil, !job.isDone, Container.shared.backgroundBrowsers().availability(job) != "live" {
            currentResult = Container.shared.backgroundBrowsers().recoveryNotice(job)
        }
        #endif
        return ["id": job.id.uuidString, "revision": job.taskRevision, "request": job.task,
            "state": job.state, "account": job.origin?.account ?? "", "message_id": job.origin?.messageID ?? "",
            "result": LiveCompactContext.bounded(job.resolution == nil ? currentResult :
                "This attempt failed historically but was resolved by confirmed retry \(job.resolution!.jobID). Do not report it as outstanding. Original outcome: " + (job.result ?? ""), bytes: 8_000),
            "result_truncated": (job.result?.utf8.count ?? 0) > 8_000,
            "deferred_archive": job.context?.deferredFeedbackArchive == true, "browser": TaskManagementTool.browserContext(job),
            "choices": (job.inputChoices ?? []).map { ["id": $0.id, "label": $0.label] },
            "rule": "This activity is in focus. Questions refer to its recorded request and result, never the email behind it. A truncated result is incomplete evidence. Use manage_task choose for an explicit candidate selection, or correct/cancel. A deferred_archive can be resumed with resume_archive only after the user explicitly asks to resume the saved archive. Earlier actions are history, not new authorization. Never dispatch a duplicate lookup while this task needs input. Stopping speech is not cancellation."]
    }

    func resolve(_ reference: String?) async throws -> DispatchJob {
        let text = (reference ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty, let selectedTaskID, let job = store.existing(selectedTaskID) { return job }
        let jobs = await store.history()
        let matches = text.isEmpty ? [] : jobs.filter {
            $0.id.uuidString.lowercased().hasPrefix(text.lowercased()) || $0.task.localizedCaseInsensitiveContains(text)
        }
        guard matches.count == 1, let job = matches.first else {
            let options = (matches.isEmpty ? Array(jobs.prefix(5)) : matches).map {
                "\($0.id.uuidString.prefix(8)) · \($0.task) · \($0.origin?.account ?? "Independent task")"
            }.joined(separator: "\n")
            throw DispatchWorker.StepFailure(message: "Choose the task to change:\n" + options)
        }
        return job
    }

    private func authorized(_ id: UUID, version: Int) throws -> DispatchJob {
        guard let job = store.existing(id), job.taskRevision == version else {
            throw DispatchWorker.StepFailure(message: "This task changed. Open its current revision before acting.")
        }
        if let reason = refusal(owner: job.userId, profile: job.profileId, origin: job.origin) {
            throw DispatchWorker.StepFailure(message: reason)
        }
        return job
    }

    func cancel(_ id: UUID, version: Int) async throws {
        let job = try authorized(id, version: version)
        #if targetEnvironment(macCatalyst)
        Container.shared.backgroundBrowsers().cancel(id)
        #endif
        if job.state == "awaiting_input" {
            await store.finish(id, state: "cancelled", result: "Cancelled while waiting for input. No further action was taken.", reportBack: false, revision: version)
            _ = await Container.shared.localTriage().release(jobId: id)
            revision += 1
            return
        }
        guard job.isRunning else { return }
        if let index = pending.firstIndex(where: { $0.id == id }) {
            pending.remove(at: index)
            await store.finish(id, state: "cancelled", result: "Cancelled before execution. Nothing was changed.", reportBack: false, revision: version)
            complete(id, value: .task(.init(text: "Cancelled before execution.", ok: false, reportBack: false, status: .cancelled)))
        } else if let task = running[id] {
            await store.setState(id, state: "cancel_requested", revision: version)
            task.cancel()
        }
        revision += 1
        RealtimeLog.log("task: \(id) revision=\(version) cancel_requested")
    }

    func choose(_ id: UUID, version: Int, choice: String) async throws {
        let job = try authorized(id, version: version)
        guard job.state == "awaiting_input", let selected = job.inputChoices?.first(where: { $0.id == choice }) else {
            throw DispatchWorker.StepFailure(message: "That choice is no longer pending. Open the current task before choosing.")
        }
        try await correct(id, version: version, instruction: "Read only the selected page: " + selected.label + ". Do not RSVP or submit anything.", linkChoice: choice)
    }

    #if targetEnvironment(macCatalyst)
    func inspectBrowser(_ id: UUID, version: Int) async throws {
        let job = try authorized(id, version: version)
        let browsers = Container.shared.backgroundBrowsers()
        select(id)
        if let existing = browsers.sessions[id], existing.current(), existing.webView != nil {
            if existing.phase == .unknown, !job.isRunning { existing.useForInspection() }
            if existing.phase != .failed { return }
            existing.cancel(); browsers.sessions[id] = nil
        }
        guard editing.insert(id).inserted else { throw DispatchWorker.StepFailure(message: "This task is already opening. Wait for its browser.") }
        defer { editing.remove(id) }
        let trace = Container.shared.voiceDiagnostics().begin(engine: "browser_inspection", userID: job.userId)
        do {
            let destination = try await browsers.inspectionDestination(job)
            _ = try authorized(id, version: version)
            let browser = try await browsers.session(id, inspectionOnly: true)
            browser.diagnostics = trace
            guard BackgroundBrowser.validURL(destination, allowLocalFixture: browser.allowLocalFixture),
                  !EmailLinkTool.stateChanging(destination) else {
                browser.cancel()
                throw BackgroundBrowser.Failure(message: "That saved link may perform an action just by opening it. Check the provider's account page directly; the earlier submission status is still unverified.")
            }
            _ = try await browser.open(destination)
            browser.message = browsers.recoveryNotice(job) + (browser.phase == .takeover ? " Use Take over to sign in and check the site." : "")
            trace.record(.turnTransition, ["transition": "browser_inspection_opened", "job_id": id.uuidString,
                "recovery": "inspection", "task_revision": String(version), "inspection_only": "true"])
        } catch {
            if let browser = browsers.sessions[id], browser.inspectionOnly {
                browser.phase = .failed
                browser.message = "Website inspection could not finish: " + error.localizedDescription
            }
            trace.record(.turnTransition, ["transition": "browser_inspection_blocked", "job_id": id.uuidString,
                "reason": error is BackgroundBrowserStore.CapacityLimit ? "capacity" : "source_or_navigation_unavailable"])
            if error is BackgroundBrowserStore.CapacityLimit {
                throw BackgroundBrowser.Failure(message: "Both task browsers are occupied. Close one before inspecting this website.")
            }
            throw error
        }
    }

    func restartBrowser(_ id: UUID, version: Int, verifiedUnsubmitted: Bool = false) async throws {
        let job = try authorized(id, version: version)
        let browsers = Container.shared.backgroundBrowsers()
        let checkedManualInspection = verifiedUnsubmitted && job.browserState == .userControlled
            && browsers.sessions[id]?.inspectionOnly == true && job.inFlightOperation == nil && job.state != "unknown"
        guard job.state == "awaiting_input", job.context != nil,
              !job.hasCommittedWrites, !job.browserOutcomeUncertain || checkedManualInspection,
              browsers.availability(job) != "live",
              job.browserState == .unsubmitted || checkedManualInspection || ((job.browserState == nil || job.browserState == .unavailable) && verifiedUnsubmitted) else {
            throw DispatchWorker.StepFailure(message: browsers.recoveryNotice(job))
        }
        browsers.sessions[id]?.cancel()
        browsers.sessions[id] = nil
        guard await store.recordBrowserState(id, state: .unsubmitted, verifiedInspection: checkedManualInspection) else {
            throw DispatchWorker.StepFailure(message: store.persistenceError ?? "Recovery could not be saved.")
        }
        try await correct(id, version: version, instruction: "Reopen the original browser task from its original source. The previous browser expired. Reinspect and refill only; any submission needs fresh approval of the new page. Earlier approvals are invalid.", restartingBrowser: true)
        RealtimeLog.log("task: \(id) browser_recovery=expired task_revision=\(version + 1) approval=required")
    }

    func resumeBrowser(_ id: UUID, version: Int, approval: UUID? = nil) async throws {
        let job = try authorized(id, version: version)
        guard job.state == "awaiting_input", let browser = Container.shared.backgroundBrowsers().sessions[id],
              browser.current(), browser.phase != .unknown, !browser.inspectionOnly else {
            throw DispatchWorker.StepFailure(message: Container.shared.backgroundBrowsers().recoveryNotice(job))
        }
        guard !job.hasCommittedWrites, job.inFlightOperation == nil else {
            throw DispatchWorker.StepFailure(message: "This task has a committed or uncertain action. Inspect its receipt before continuing; nothing was repeated.")
        }
        let previousPhase = browser.phase
        if let approval { try browser.approve(approval) }
        else {
            guard browser.phase != .approval else { throw DispatchWorker.StepFailure(message: "The form is open in the center pane. Use its Approve button, or inspect its exact approval ID and resume_browser after the user explicitly approves. Nothing was submitted; do not dispatch a new task.") }
            try browser.resume()
        }
        do {
            try await correct(id, version: version, instruction: "Continue the original browser task.", resumingBrowser: true)
        } catch {
            browser.authorizedSubmission = nil
            browser.phase = previousPhase
            throw error
        }
    }
    #endif

    func correct(_ id: UUID, version: Int, instruction: String, linkChoice: String? = nil, resumingBrowser: Bool = false, restartingBrowser: Bool = false) async throws {
        let original = try authorized(id, version: version)
        guard !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              original.context != nil, original.command == nil || original.state == "awaiting_input" else {
            throw DispatchWorker.StepFailure(message: "Use the Commands editor and the existing unfinished-step retry for a saved command. No step was repeated.")
        }
        guard editing.insert(id).inserted else { throw DispatchWorker.StepFailure(message: "A correction is already pending for this task.") }
        defer { editing.remove(id) }
        if original.isRunning {
            try await cancel(id, version: version)
            _ = await result(id)
        }
        let settled = try authorized(id, version: version)
        guard !settled.hasCommittedWrites, settled.state != "unknown", settled.inFlightOperation == nil else {
            throw DispatchWorker.StepFailure(message: "This task has committed or uncertain actions. Review its receipts and reconcile provider state before starting changed work. No action was repeated.")
        }
        let updated = resumingBrowser || restartingBrowser ? original.task : original.task + "\nUser correction (same source and scope): " + instruction
        guard await store.revise(id, revision: version, task: updated, linkChoice: linkChoice), let row = store.existing(id), let context = row.context else {
            throw DispatchWorker.StepFailure(message: store.persistenceError ?? "The task changed before the correction could be saved.")
        }
        results[id] = nil
        _ = await Container.shared.localTriage().release(jobId: id)
        let source = row.origin.map { GmailReadTools.json(["account": $0.account, "id": $0.messageID,
            "threadId": $0.threadID, "from": $0.sender, "subject": $0.subject]) }
        let job = DispatchWorker.Job(id: id, task: updated, account: row.origin?.account,
            facts: context.facts + (restartingBrowser ? [instruction] : resumingBrowser ? ["The user resumed this task's existing browser. Call task_browser inspect before continuing the original objective; it will execute any exact approved action first. Do not reopen the starting URL or repeat a submission."] : []), standingOnJSON: source, authoredAt: context.authoredAt,
            authoredTimeZone: TimeZone(identifier: context.timeZone),
            expects: .init(rawValue: context.expects), scope: .init(rawValue: context.scope),
            commandSteps: row.command.map { Array($0.actions.dropFirst($0.completedSteps)) }, command: row.command,
            profileId: row.profileId,
            revision: context.revision, inputSource: "correction", parksSource: context.parksSource,
            holdsDecision: context.holdsDecision, dependencyID: context.dependencyID, linkChoice: context.linkChoice,
            userRequest: resumingBrowser || restartingBrowser ? context.userRequest : instruction)
        schedule(job, owner: row.userId, origin: row.origin, version: context.revision)
        RealtimeLog.log("task: \(id) revision=\(context.revision) correction_accepted")
    }

    func setPreference(_ id: UUID, version: Int, preference: DispatchJob.CompletionPreference) async throws {
        _ = try authorized(id, version: version)
        _ = await store.setPreference(id, revision: version, preference: preference)
        if let error = store.persistenceError { throw DispatchWorker.StepFailure(message: error) }
        if let job = store.existing(id), job.isDone, preference == .quiet {
            _ = await Container.shared.localTriage().release(jobId: id)
        }
        revision += 1
    }

    func reviewed(_ id: UUID, version: Int) async throws {
        let job = try authorized(id, version: version)
        guard !job.isRunning else { return }
        await store.settle(id)
        _ = await Container.shared.localTriage().release(jobId: id)
        revision += 1
    }

    private func complete(_ id: UUID, value: Result) {
        results[id] = value
        for waiter in waiters.removeValue(forKey: id) ?? [] { waiter.resume(returning: value) }
    }

    func run(_ job: DispatchWorker.Job) async -> FullDuplexBroker.DispatchOutcome {
        let id = await submit(job)
        guard case .task(let outcome) = await result(id) else {
            return .init(text: "The task identifier belongs to a different action.", ok: false, status: .failed)
        }
        return outcome
    }

    func perform(id: UUID = UUID(), name: String, arguments: String, profile: String?,
                 origin: DispatchJob.MailOrigin?, conversationID: UUID? = nil, turnID: String? = nil,
                 diagnostics: VoiceDiagnostics.Session? = nil, inputSource: String = "unknown") async -> FullDuplexBroker.ToolResult {
        let args = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any] ?? [:]
        let explicitOrigin = DispatchJob.MailOrigin.from(["account": args["account"] ?? "", "id": args["message_id"] ?? args["id"] ?? ""])
        if let origin, let explicitOrigin,
           origin.account.lowercased() != explicitOrigin.account.lowercased() || origin.messageID != explicitOrigin.messageID {
            return .init(text: "The requested action does not match the authorized email. Nothing was changed.", ok: false)
        }
        let origin = origin ?? explicitOrigin
        let owner = backend.userId
        let mailSource = origin.map { GmailManageTools.WriteSource(
            cursor: .init(messageId: $0.messageID, account: $0.account, senders: []),
            ownerID: owner, profileID: profile) }
        let sourceHash = diagnostics.flatMap { session in origin.map {
            session.target(MailSelection(account: $0.account, messageID: $0.messageID).canonical)
        } } ?? "none"
        let key = [owner ?? "", profile ?? "", name, arguments].joined(separator: "|")
        if let previous = operationIDs[key], accepted.contains(previous) {
            if case .tool(let result) = await result(previous) { return result }
        }
        guard accepted.insert(id).inserted else {
            if case .tool(let result) = await result(id) { return result }
            return .init(text: "This action identifier has already been used.", ok: false)
        }
        if store.contains(id) {
            let value = FullDuplexBroker.ToolResult(text: store.existing(id)?.result ?? "This action already exists; check its outcome before retrying.", ok: nil)
            results[id] = .tool(value)
            return value
        }
        operationIDs[key] = id
        await store.begin(id: id, task: LiveFastAction(rawValue: name)?.title ?? ToolNarration.progressLabel(for: name),
            profileId: profile, conversationId: conversationID, turnId: turnID, origin: origin,
            quickMailAction: .captured(tool: name, arguments: args, origin: origin))
        let source = ["voice", "button", "keyboard", "typed"].contains(inputSource) ? inputSource : "unknown"
        guard await store.acceptContext(id, context: .init(scope: "current_email", expects: "receipt", authoredAt: Date(), timeZone: TimeZone.current.identifier, input: source), preference: .quiet) else {
            let value = FullDuplexBroker.ToolResult(text: store.persistenceError ?? "Task could not be saved.", ok: false)
            results[id] = .tool(value)
            return value
        }
        enqueue(id: id, owner: owner, profile: profile, origin: origin) { [self] in
            if let reason = refusal(owner: owner, profile: profile, origin: origin) {
                await store.finish(id, state: "failed", result: reason)
                return .tool(.init(text: reason, ok: false))
            }
            await store.setState(id, state: "running")
            diagnostics?.record(.jobStarted, ["job_id": id.uuidString, "tool": name, "input_source": source,
                "target_hash": sourceHash, "attribution": mailSource == nil ? "foreground" : "accepted_source"])
            guard !Task.isCancelled, await store.markOperation(id, revision: 1, callID: id.uuidString) else {
                await store.finish(id, state: "cancelled", result: "Cancelled before execution.", revision: 1)
                return .tool(.init(text: "Cancelled before execution.", ok: false))
            }
            let value = await FullDuplexBroker.runTool(name: name, argumentsJSON: arguments,
                conversationId: conversationID?.uuidString, profileId: profile, mailSource: mailSource,
                mailJobID: id, mailCallID: id.uuidString, diagnostics: diagnostics)
            let pending = value.pendingArchive != nil || value.pendingDraft != nil || value.deferred
            if !pending {
                await store.receipt(id, callId: id.uuidString, tool: name, failed: value.ok != true,
                    targetHash: diagnostics?.target(VoiceDiagnostics.targetIdentity(arguments: arguments) ?? "unknown"))
            }
            if !pending, !value.outcomeUnknown, value.ok == true || !Task.isCancelled { _ = await store.markOperation(id, revision: 1, callID: nil) }
            let state = pending || value.outcomeUnknown || (Task.isCancelled && value.ok != true) ? "unknown" : value.ok == true ? "done" : value.effects?.isEmpty == false ? "partial" : "failed"
            await store.finish(id, state: state, result: value.text, reportBack: pending || value.ok != true)
            if state == "done", let origin { await store.releaseDecisionHold(.init(account: origin.account, messageID: origin.messageID)) }
            diagnostics?.record(.jobFinished, ["job_id": id.uuidString, "outcome": state,
                "target_hash": sourceHash, "attribution": mailSource == nil ? "foreground" : "accepted_source"])
            return .tool(value)
        }
        guard case .tool(let value) = await result(id) else { return .init(text: "The task result is unavailable.", ok: false) }
        // Deduplicate overlapping acceptance; a later deliberate click may retry a refused operation.
        if value.ok != true, !value.deferred { operationIDs[key] = nil }
        return value
    }

    private func enqueue(id: UUID, owner: String?, profile: String?, origin: DispatchJob.MailOrigin?, run: @escaping () async -> Result) {
        let identity = origin.map { MailSelection(account: $0.account, messageID: $0.threadID.isEmpty ? $0.messageID : $0.threadID).canonical } ?? id.uuidString
        pending.append(.init(id: id, target: [owner ?? "", profile ?? "", identity].joined(separator: "|"), run: run))
        revision += 1
        drain()
    }

    private func drain() {
        while running.count < capacity, let index = pending.firstIndex(where: { !targets.values.contains($0.target) }) {
            let work = pending.remove(at: index)
            targets[work.id] = work.target
            running[work.id] = Task { [self] in
                let value = await work.run()
                complete(work.id, value: value)
                running[work.id] = nil
                targets[work.id] = nil
                revision += 1
                drain()
            }
        }
    }

    func result(_ id: UUID) async -> Result {
        if let value = results[id] { return value }
        return await withCheckedContinuation { waiters[id, default: []].append($0) }
    }

    func job(request: String, commandID: String?, origin: DispatchJob.MailOrigin, profile: String?) throws -> DispatchWorker.Job {
        if let reason = refusal(owner: backend.userId, profile: profile, origin: origin) {
            throw DispatchWorker.StepFailure(message: reason)
        }
        let target: [String: Any] = ["account": origin.account, "id": origin.messageID,
            "threadId": origin.threadID, "from": origin.sender, "subject": origin.subject]
        var job = DispatchWorker.Job(id: UUID(), task: request, account: origin.account,
            standingOnJSON: GmailReadTools.json(target), authoredAt: Date(), authoredTimeZone: .current,
            expects: .answer, scope: .currentEmail, profileId: profile, inputSource: "typed", completionPreference: .requested(in: request),
            ownerID: backend.userId, userRequest: request)
        if let commandID {
            guard let saved = Container.shared.customCommands().commands.first(where: { $0.id == commandID }),
                  saved.enabled, !saved.actions.isEmpty else {
                throw DispatchWorker.StepFailure(message: "That command is disabled or no longer exists. No task was started.")
            }
            job.task = "Run saved command “\(saved.title)” on the selected email."
            if let reason = CustomCommandRules.accountRefusal(saved.actions, account: origin.account) {
                throw DispatchWorker.StepFailure(message: reason)
            }
            job.command = .init(keyword: saved.keyword, actions: saved.actions)
            job.commandSteps = saved.actions
            job.expects = CustomCommandRules.dispatchExpects(saved.actions)
        }
        return job
    }

    func next(queue: LocalTriageQueue, input: LocalTriageQueue.Input = .init(), store: MailStore,
              dealtWith: Bool = true) async -> (output: String, served: LocalTriageQueue.Served) {
        if let source = await queue.standingOnJSON,
           let origin = DispatchJob.MailOrigin.from(DispatchWorker.target(standingOnJSON: source, facts: [])) {
            await self.store.releaseDecisionHold(.init(account: origin.account, messageID: origin.messageID))
        }
        return await queue.step(input, store: store, dealtWith: dealtWith)
    }
}
