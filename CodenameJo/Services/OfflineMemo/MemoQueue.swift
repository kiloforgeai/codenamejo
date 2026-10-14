import FactoryKit
import Foundation

/// Holds spoken notes on disk until they can be sent; a memo's id is its dispatch job id.
/// Has no speaking path on purpose: `DispatchJobStore.recover()` speaks answers, so speaking here would double them.
@MainActor
final class MemoQueue: ObservableObject {

    @Published private(set) var items: [QueuedMemo] = []

    /// How long an unsent memo is kept; matches `DispatchJob.retention`.
    private static let retention: TimeInterval = 30 * 24 * 60 * 60

    @Injected(\.backend) private var backend
    @Injected(\.dispatchJobs) private var dispatchJobs
    @Injected(\.memoTranscriber) private var transcriber

    /// Whether a drain is already walking the queue. See `drain`.
    private var draining = false

    /// Set around a live call. A memo posting during a call would be a concurrent agent
    /// that `maxLiveDispatches` cannot see, because that cap counts only the dispatches
    /// the call itself started.
    var isPaused = false

    private var manifestURL: URL {
        MemoRecorder.directory.appendingPathComponent("memos.json")
    }

    init() {
        // The feature gate: off, `items` stays empty and every caller sees a no-op queue.
        guard VoiceSettings.voiceNotes else { return }
        items = Self.load(from: MemoRecorder.directory.appendingPathComponent("memos.json"))
        // Transcription and sending both die with the process, so stranded rows go back.
        for index in items.indices where items[index].state == .sending {
            items[index].state = .ready
        }
        for index in items.indices where items[index].state == .transcribing {
            items[index].state = .awaitingModel
        }
        save()
    }

    // MARK: - Capture

    /// Take ownership of a finished recording. The id comes from the `<uuid>.m4a` filename,
    /// so the file and the dispatch job can never disagree.
    func enqueue(_ url: URL, profileId: String? = nil) {
        // Read live, not from `init`: the switch may have changed since launch.
        guard VoiceSettings.voiceNotes else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else {
            RealtimeLog.log("memos: \(url.lastPathComponent) is not a memo filename; discarding")
            try? FileManager.default.removeItem(at: url)
            return
        }
        guard !items.contains(where: { $0.id == id }) else { return }
        items.insert(
            QueuedMemo(id: id, filename: url.lastPathComponent, state: .transcribing, profileId: profileId),
            at: 0)
        save()
        RealtimeLog.log("memos: queued \(url.lastPathComponent)")
        Task { await transcribePending() }
    }

    // MARK: - Transcription

    /// Give every memo without a transcript another go, e.g. once the speech model arrives.
    func transcribePending() async {
        await transcribeWaiting()
        // Kept outside `transcribeWaiting`, whose early returns would otherwise skip the drain.
        await drain()
    }

    private func transcribeWaiting() async {
        let pending = items.filter { $0.state == .awaitingModel || $0.state == .transcribing }
        guard !pending.isEmpty else { return }

        await transcriber.ensureModel()
        guard transcriber.readiness.canTranscribe else {
            // Not a failure: `awaitingModel` keeps the audio for the next attempt.
            for memo in pending where memo.state == .transcribing {
                update(memo.id) { $0.state = .awaitingModel }
            }
            return
        }

        for memo in pending {
            guard FileManager.default.fileExists(atPath: memo.localURL.path) else {
                RealtimeLog.log("memos: \(memo.filename) is gone; dropping it")
                items.removeAll { $0.id == memo.id }
                save()
                continue
            }

            update(memo.id) { $0.state = .transcribing }
            do {
                let text = try await transcriber.transcribe(fileAt: memo.localURL)
                update(memo.id) {
                    $0.transcript = text
                    $0.state = .ready
                    $0.lastError = nil
                }
                RealtimeLog.log("memos: transcribed \(memo.filename) — \(text.count) chars")
            } catch {
                // `needsReview`, never an empty transcript: an empty task must not reach an agent that sends mail.
                update(memo.id) {
                    $0.state = .needsReview
                    $0.lastError = error.localizedDescription
                }
                RealtimeLog.log("memos: could not transcribe \(memo.filename) — "
                    + error.localizedDescription)
            }
        }
    }

    /// Replace a transcript the user corrected.
    func updateTranscript(_ text: String, for id: UUID) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        update(id) {
            $0.transcript = trimmed
            // An edit rescues a `needsReview` row; blanking one puts it back.
            if $0.state == .needsReview || $0.state == .ready || $0.state == .failed {
                $0.state = trimmed.isEmpty ? .needsReview : .ready
                $0.lastError = nil
            }
        }
    }

    // MARK: - Sending

    /// Send every ready note, oldest first, with no human read-back.
    /// Only an empty transcript (`needsReview`) or a sub-0.7s tap stops a misheard note.
    func drain() async {
        // One drain at a time: overlapping drains would both send a note before either marked it `.sending`.
        guard !draining else { return }
        draining = true
        defer { draining = false }

        // An unreachable OpenAI leaves a note `.ready` for the next trigger.
        guard !isPaused, backend.userId != nil else {
            if !items.isEmpty {
                RealtimeLog.log("memos: holding \(items.count) note(s) — "
                    + (isPaused ? "a call is up" : "not signed in"))
            }
            return
        }

        let ready = items.filter(\.isSendable).sorted { $0.capturedAt < $1.capturedAt }
        guard !ready.isEmpty else {
            if !items.isEmpty {
                // Everything is `needsReview`, mid-transcription, or out of attempts.
                RealtimeLog.log("memos: \(items.count) note(s) on hand, none sendable")
            }
            return
        }

        RealtimeLog.log("memos: sending \(ready.count) note(s)")
        for memo in ready {
            // Re-checked per note: a dial can land between two jobs, and a note run after
            // it is a write-capable agent `maxLiveDispatches` cannot see.
            guard !isPaused else {
                RealtimeLog.log("memos: stopping the drain — a call started")
                return
            }
            await send(memo.id)
        }
    }

    /// Hand a memo to the dispatch worker.
    func send(_ id: UUID) async {
        guard !isPaused,
              let memo = items.first(where: { $0.id == id }),
              memo.isSendable
        else { return }

        guard backend.userId != nil else {
            // Does not burn an attempt: signed-out resolves on its own.
            update(id) { $0.state = .ready; $0.lastError = "Not signed in." }
            return
        }

        // The state is what stops a note being sent twice: `isSendable` excludes `.sending`.
        update(id) { $0.state = .sending; $0.lastError = nil }
        let outcome = await DispatchWorker.run(DispatchWorker.Job(
            id: memo.id, task: memo.transcript,
            authoredAt: memo.capturedAt, authoredTimeZone: TimeZone(identifier: memo.capturedTimeZone),
            profileId: memo.profileId))
        if outcome.recorded {
            // The job is in the dispatch log, which delivers its answer — done whatever it said.
            settle(id)
        } else {
            // Never reached OpenAI: no attempt is burned, and the next trigger tries again.
            update(id) {
                $0.state = .ready
                $0.lastError = OpenAIKeyService.current == nil ? "Add your OpenAI key in Settings." : "Couldn't reach OpenAI."
            }
        }
    }

    /// Drop a memo the dispatch log has taken, and its audio with it.
    private func settle(_ id: UUID) {
        guard let memo = items.first(where: { $0.id == id }) else { return }
        try? FileManager.default.removeItem(at: memo.localURL)
        items.removeAll { $0.id == id }
        save()
        RealtimeLog.log("memos: \(memo.filename) ran as a dispatched job")
    }

    /// Forget a memo and delete whatever is still on disk.
    func remove(_ id: UUID) {
        guard let memo = items.first(where: { $0.id == id }) else { return }
        try? FileManager.default.removeItem(at: memo.localURL)
        items.removeAll { $0.id == id }
        save()
    }

    /// Drop every queued note attributed to a deleted profile — its dispatch would 404.
    func purge(profileId: String) {
        for memo in items where memo.profileId == profileId { remove(memo.id) }
    }

    // MARK: - Launch reconciliation

    /// Settle anything the dispatch log already has, and sweep what nobody wants. Call once per launch.
    func reconcile() async {
        sweep()
        guard !items.isEmpty else { return }
        let known = Set(await dispatchJobs.history().map(\.id))
        for memo in items where known.contains(memo.id) && memo.state != .sending {
            settle(memo.id)
        }
    }

    /// Delete every note on sign-out, or the next account's session would dispatch them.
    /// Removes the whole directory so it works even when `init` gated the queue off.
    func discardEverything() {
        items = []
        try? FileManager.default.removeItem(at: MemoRecorder.directory)
        RealtimeLog.log("memos: discarded every note on sign-out")
    }

    /// Drop what has aged out, and any audio no row claims (a crash before the manifest write leaves orphans).
    private func sweep() {
        let cutoff = Date().addingTimeInterval(-Self.retention)
        let expired = items.filter { $0.capturedAt < cutoff }
        for memo in expired {
            try? FileManager.default.removeItem(at: memo.localURL)
        }
        if !expired.isEmpty {
            items.removeAll { $0.capturedAt < cutoff }
            save()
            RealtimeLog.log("memos: swept \(expired.count) past retention")
        }

        let claimed = Set(items.map(\.filename))
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: MemoRecorder.directory, includingPropertiesForKeys: nil)) ?? []
        for file in contents where file.pathExtension == "m4a" && !claimed.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
            RealtimeLog.log("memos: removed orphaned \(file.lastPathComponent)")
        }
    }

    // MARK: - Persistence

    private func update(_ id: UUID, _ change: (inout QueuedMemo) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
        save()
    }

    /// Written atomically on every change, so a force-quit or reboot loses nothing.
    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: manifestURL, options: .atomic)
    }

    private static func load(from url: URL) -> [QueuedMemo] {
        guard let data = try? Data(contentsOf: url),
              let items = try? JSONDecoder().decode([QueuedMemo].self, from: data)
        else { return [] }
        return items
    }
}

// MARK: - Read-only views

extension MemoQueue {
    /// How many memos are waiting on a Send tap — the badge's number.
    var readyCount: Int { items.filter(\.isSendable).count }

    /// True while a memo is posting, for the log line at connect. Logged, not enforced:
    /// a memo landing just after a dial is recovered on the next connect.
    var hasSendingItems: Bool { items.contains { $0.state == .sending } }
}
