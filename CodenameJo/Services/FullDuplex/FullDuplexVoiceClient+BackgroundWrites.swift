import Foundation

extension FullDuplexVoiceClient {

    // MARK: - Background writes

    /// Start a write, say it is going, and report how it went afterwards.
    ///
    /// **The same trade dispatch makes, and deliberately not the same mechanism.**
    /// Routing a write through `dispatch` would hand a *sentence* to a second agent
    /// that re-decides it: that agent gets no transcript, so it cannot know what the
    /// user actually asked for, and it would re-compose the arguments from a
    /// paraphrase. For the writes that still take a confirm, consent would stop
    /// existing at the request boundary — the exact shape of the HMAC `confirm_token`
    /// that had to be deleted. Here the model's own arguments are relayed verbatim,
    /// so nothing re-decides anything and the two-turn confirm upstream is untouched.
    /// All that moves is *when* the outcome arrives.
    ///
    /// **`send_email` no longer has a confirm upstream, and that makes verbatim
    /// relaying matter more rather than less** (2026-08-05).
    /// The recipient address is now the only guard on a send: the model resolves it
    /// with `find_person` and says it out loud afterwards. A second agent
    /// re-deciding a write would re-resolve that address from a sentence, off a
    /// transcript it never saw, with nothing downstream to catch it.
    ///
    /// **That last sentence used to end "so the one thing this path must never do is
    /// exactly the thing `dispatch` does", and on 2026-08-10 `dispatch` stopped doing
    /// it.** The diagnosis was right and the conclusion was too broad: the danger was
    /// never handing work to a second agent, it was handing it a *name* and letting the
    /// second agent decide what the name meant. So the `dispatch` tool now
    /// carries the resolved values as arguments — `account` is injected into the worker's
    /// tool calls by `DispatchWorker`, `facts` states every address and id the caller worked out —
    /// and the worker is told in as many words not to re-resolve anything it was given
    /// or to guess at anything it was not.
    ///
    /// **What did not change is the thing worth keeping in sight.** A dispatched job
    /// still re-decides whatever the caller left unpinned; the guard is that the caller
    /// pins it, not that the second agent has become trustworthy. And this path is
    /// still the better shape for a *single* write the user is waiting on, because
    /// verbatim relaying needs no discipline from anybody. The two are for different
    /// jobs: one call the user asked for goes here; a job of many calls goes to the
    /// second agent.
    ///
    /// So this is `startDispatch`'s shape pointed at a local write: post the
    /// acknowledgement before the first `await`, run the relay in a task nothing waits
    /// on, and let `drainDispatchReports` deliver the outcome in a gap. The
    /// acknowledgement is honest at the moment it is posted — the request is issued
    /// immediately, never queued behind another write — because a send the user hangs
    /// up on before it was ever attempted would be a claim about mail that does not
    /// exist.
    func startBackgroundWrite(callId: String, name: String, argumentsJSON: String) {
        // An empty call id would collide with any other in `backgroundWrites`,
        // orphaning a task `teardown` can no longer cancel and dropping the survivor's
        // handle. `RealtimeEvent` decodes `call_id` with an empty-string fallback, so
        // this is reachable from a malformed frame rather than only from a bug — and
        // an output posted against no call id draws an `error` frame, which is not in
        // `benignErrorCodes` and would end the call. Blocking is the safe fallback.
        guard !callId.isEmpty else {
            RealtimeLog.log("write: \(name) arrived with no call id — relaying inline")
            runFunctionToolBlocking(callId: callId, name: name, argumentsJSON: argumentsJSON)
            return
        }
        guard backgroundWrites.count < Self.maxLiveBackgroundWrites else {
            RealtimeLog.log("write: refused \(name) — \(backgroundWrites.count) already "
                + "in flight")
            postDispatchOutput(callId: callId, startedWork: false, output:
                "Not started — \(backgroundWrites.count) other writes are still going. "
                + "Tell the user that plainly and wait for one to come back before "
                + "trying this again. Do not say this one was sent.")
            return
        }

        RealtimeLog.log("write: \(name) starting in the background")
        FullDuplexTrace.note("!! background write \(name)")
        onToolUse?(name)

        // Before the request, like a dispatch's. The wording has to make the model say
        // it is *going* rather than that it went.
        postDispatchOutput(callId: callId, output:
            "Started — this is an acknowledgement, not a result. Say it is going, "
            + "never that it went, then stop. How it went arrives later as a note in "
            + "this conversation. Do not call this tool again.")

        let dial = dialGeneration
        let profileId = ProfileRuntime.snapshot?.profileId
        backgroundWrites[callId] = Task { [weak self] in
            let result = await HangUpRunway.run("Finishing a write") {
                await FullDuplexBroker.runTool(name: name, argumentsJSON: argumentsJSON)
            }
            guard let self, !Task.isCancelled else { return }
            guard self.isActive, dial == self.dialGeneration else {
                self.recordOrphanedWrite(tool: name, summary: Self.writeSummary(argumentsJSON),
                                         text: result.text, ok: result.ok, profileId: profileId)
                return
            }
            self.backgroundWrites[callId] = nil
            self.onToolDone?(name)
            RealtimeLog.log("write: \(name) came back "
                + "(ok=\(result.ok.map(String.init(describing:)) ?? "unclassified")) — "
                + "\(result.text.prefix(80))")
            self.pendingReports.append(DispatchReport(
                kind: .write(tool: name, movedPast: false), jobId: nil,
                task: Self.writeSummary(argumentsJSON),
                text: result.text, ok: result.ok, landedAt: .now, delivery: .standard,
                origin: nil))
            self.drainDispatchReports()
        }
    }

    /// Enough of a write's arguments to name it in a report, and no more.
    ///
    /// The outcome lands after the conversation has moved on, so "that didn't go"
    /// with no subject is the same non-sequitur a dispatched answer would be. `to`
    /// and `title` are what a user would recognise; a body is content and a page id is
    /// an identifier the prompt forbids speaking, so neither belongs here.
    private static func writeSummary(_ argumentsJSON: String) -> String {
        let arguments = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8)))
            as? [String: Any] ?? [:]
        let fields = ["to", "subject", "summary", "title"].compactMap { key -> String? in
            guard let value = arguments[key] as? String, !value.isEmpty else { return nil }
            return "\(key): \(value.prefix(80))"
        }
        return fields.isEmpty ? "no details" : fields.joined(separator: ", ")
    }

    /// A write that came back after its call ended, filed where the next call's opening
    /// reads (`DispatchJobStore.recover`). Only a confirmed success stays silent, as with
    /// a receipt job.
    func recordOrphanedWrite(tool: String, summary: String, text: String, ok: Bool?,
                                     profileId: String?) {
        let id = UUID()
        dispatchJobs.begin(id: id, task: "\(tool) — \(summary)", profileId: profileId)
        dispatchJobs.finish(id, state: ok == false ? "failed" : "done", result: text, reportBack: ok != true)
        RealtimeLog.log("write: \(tool) came back after its call ended "
            + "(ok=\(ok.map(String.init(describing:)) ?? "unclassified")) — recorded for the next call")
    }
}
