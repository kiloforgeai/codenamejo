import FactoryKit
import Foundation

extension FullDuplexVoiceClient {
    func makeEmailReader() -> EmailReadAloudController {
        EmailReadAloudController(fetch: { [weak self] reading in
            guard let self, self.emailReadIsCurrent(reading) else { throw CancellationError() }
            let step = self.standingStep.map(self.preparedEmailStep) ?? ""
            let payload = (try? JSONSerialization.jsonObject(with: Data(step.utf8))) as? [String: Any]
            let content = (payload?["item"] as? [String: Any])?["emailContent"]
            let prepared = content.flatMap { try? JSONSerialization.data(withJSONObject: $0) }
                .flatMap { try? JSONDecoder().decode(FeedEmailContent.self, from: $0) }?
                .messages.first { $0.id == reading.selection.messageID }
            return try await FullEmailSource.read(selection: reading.selection, threadID: reading.threadID,
                prepared: prepared, fetch: {
                    guard self.emailReadIsCurrent(reading) else { throw CancellationError() }
                    _ = try GmailReadTools.targets(["account": reading.selection.account])
                    let token = try await GmailReadTools.token(reading.selection.account)
                    try Task.checkCancellation()
                    guard self.emailReadIsCurrent(reading) else { throw CancellationError() }
                    return try await GmailAPI.fullMessage(token: token, id: reading.selection.messageID)
                }, attachment: { id in
                    guard self.emailReadIsCurrent(reading) else { throw CancellationError() }
                    let token = try await GmailReadTools.token(reading.selection.account)
                    try Task.checkCancellation()
                    guard self.emailReadIsCurrent(reading) else { throw CancellationError() }
                    return try await GmailAPI.attachment(token: token, messageId: reading.selection.messageID, attachmentId: id)
                })
        }, isCurrent: { [weak self] in self?.emailReadIsCurrent($0) == true }, speak: { [weak self] text, current in
            self?.transport?.liveAdapter?.speakExactly(text, ifCurrent: current)
        }, stopSpeech: { [weak self] in
            guard let self else { return }
            if self.responseInFlight { self.transport?.cancelResponse() }
            self.transport?.clearOutputAudio()
        }, failure: { [weak self] message in
            guard let self, self.isActive else { return }
            self.onRecoverableNotice?(message)
            self.transport?.liveAdapter?.speakExactly(message)
        }, trace: { [weak self] reading, event in
            guard let self else { return }
            var fields = ["transition": "email_read_" + event, "request_id": reading.id.uuidString,
                "phase": reading.phase.rawValue, "chunk_index": String(reading.cursor),
                "chunk_count": String(reading.chunks.count), "source_bytes": String(reading.sourceBytes),
                "completed_bytes": String(reading.completedBytes), "cached": String(reading.cached)]
            fields["target_hash"] = self.diagnostics?.target(reading.selection.canonical)
            self.diagnostics?.record(.turnTransition, fields)
        })
    }

    func emailReadIsCurrent(_ reading: EmailReadAloud) -> Bool {
        guard isActive, !MailBodyCache.withheld,
              reading.ownerID == Container.shared.backend().userId,
              reading.profileID == ProfileRuntime.snapshot?.profileId,
              let key = standingStep.flatMap(LiveEmailPresentation.Key.selection), key.selectedIDs.count == 1,
              key.account.caseInsensitiveCompare(reading.selection.account) == .orderedSame,
              key.selectedIDs.first == reading.selection.messageID,
              (key.messageThreads?[reading.selection.messageID] ?? key.threadId) == reading.threadID,
              ProfileRuntime.allowedMailAccounts(GoogleAccountStore.mailAccounts()).contains(where: {
                  $0.caseInsensitiveCompare(reading.selection.account) == .orderedSame
              }) else { return false }
        return true
    }

    func tryEmailReadAloud(_ text: String) -> Bool {
        guard isActive, let adapter = transport?.liveAdapter else { return false }
        guard let intent = EmailReadAloud.intent(text, retryPending: emailReader.reading?.retryPending == true) else {
            emailReader.reading?.retryPending = false
            return false
        }
        guard intent == .start || emailReader.reading != nil else { return false }
        emailReadTurn = liveUserTurn
        adapter.resolveLocalInput(applicationResult:
            "The application owns this full-email reading request and its retry. Do not summarize, delegate, advance, write, or ask which part. Wait for its exact reading or failure.", allowPresentation: false)
        switch intent {
        case .start:
            guard !MailBodyCache.withheld else {
                adapter.speakExactly("Only email headers are available in this profile. Enable full email access before reading the message aloud.")
                return true
            }
            guard let key = standingStep.flatMap(LiveEmailPresentation.Key.selection), key.selectedIDs.count == 1,
                  let id = key.selectedIDs.first else {
                adapter.speakExactly("Select one email to read in full. A grouped card does not identify which message to read.")
                return true
            }
            adapter.cancelPreparedEmail()
            emailReader.start(.init(selection: .init(account: key.account, messageID: id),
                threadID: key.messageThreads?[id] ?? key.threadId, profileID: ProfileRuntime.snapshot?.profileId,
                ownerID: Container.shared.backend().userId))
        case .pause: emailReader.pause()
        case .resume, .retry:
            if emailReader.valid() { emailReader.resume() }
            else { adapter.speakExactly("That reading no longer matches the selected email. Ask me to read the email now in focus.") }
        }
        return true
    }
}
