import Foundation
import XCTest
@testable import CodenameJo

/// A voice note is a task an agent carries out with nobody listening, so the queue's states
/// are the safety design: a transcription or a send killed mid-flight has to come back, an
/// empty transcript must never be sendable, and a deleted profile's note must not be
/// dispatched under whichever profile is selected next.
@MainActor
final class MemoQueueStateTests: XCTestCase {
    private var previousSetting: Any?
    private var previousOwner: Any?

    override func setUp() async throws {
        try await super.setUp()
        previousSetting = UserDefaults.standard.object(forKey: VoiceSettings.Key.voiceNotes)
        previousOwner = UserDefaults.standard.object(forKey: VoiceNotesDefault.ownerKey)
        UserDefaults.standard.set(true, forKey: VoiceSettings.Key.voiceNotes)
        VoiceNotesDefault.stamp("test-user")
        removeManifest()
    }

    override func tearDown() async throws {
        removeManifest()
        UserDefaults.standard.set(previousSetting, forKey: VoiceSettings.Key.voiceNotes)
        UserDefaults.standard.set(previousOwner, forKey: VoiceNotesDefault.ownerKey)
        try await super.tearDown()
    }

    private var manifestURL: URL { MemoRecorder.directory.appendingPathComponent("memos.json") }

    private func removeManifest() { try? FileManager.default.removeItem(at: manifestURL) }

    private func writeManifest(_ memos: [QueuedMemo]) throws {
        try JSONEncoder().encode(memos).write(to: manifestURL, options: .atomic)
    }

    private func memo(
        _ id: UUID = UUID(), state: QueuedMemo.State, transcript: String = "send the invoice",
        attempts: Int = 0, profileId: String? = nil, capturedAt: Date = Date()
    ) -> QueuedMemo {
        QueuedMemo(id: id, filename: "\(id.uuidString).m4a", capturedAt: capturedAt,
                   capturedTimeZone: "Europe/London", transcript: transcript, state: state,
                   attempts: attempts, lastError: nil, profileId: profileId)
    }

    func testATranscriptionOrSendStrandedByAKillIsResetAtLaunch() throws {
        let stranded = memo(state: .transcribing)
        let inFlight = memo(state: .sending)
        let reviewed = memo(state: .needsReview, transcript: "")
        try writeManifest([stranded, inFlight, reviewed])
        let queue = MemoQueue()
        XCTAssertEqual(queue.items.first(where: { $0.id == stranded.id })?.state, .awaitingModel)
        // A send is the dispatch worker running inside this process, so a kill ends it
        // before the dispatch log records it; the row goes back to `.ready` to be sent again.
        XCTAssertEqual(queue.items.first(where: { $0.id == inFlight.id })?.state, .ready)
        XCTAssertEqual(queue.items.first(where: { $0.id == reviewed.id })?.state, .needsReview)
        XCTAssertFalse(queue.hasSendingItems)
        XCTAssertEqual(queue.readyCount, 1)
    }

    func testTheFeatureSwitchOffLeavesTheQueueEmptyRatherThanReadingTheManifest() throws {
        try writeManifest([memo(state: .ready)])
        UserDefaults.standard.set(false, forKey: VoiceSettings.Key.voiceNotes)
        let queue = MemoQueue()
        XCTAssertTrue(queue.items.isEmpty)
        XCTAssertEqual(queue.readyCount, 0)
        XCTAssertFalse(queue.hasSendingItems)
    }

    func testEditingATranscriptRescuesAReviewRowAndBlankingItPutsItBack() throws {
        let one = memo(state: .needsReview, transcript: "")
        try writeManifest([one])
        let queue = MemoQueue()
        queue.updateTranscript("  tell Sam the quote is ready  ", for: one.id)
        XCTAssertEqual(queue.items.first?.state, .ready)
        // Stored trimmed, because this text becomes the task itself.
        XCTAssertEqual(queue.items.first?.transcript, "tell Sam the quote is ready")
        XCTAssertEqual(queue.readyCount, 1)
        queue.updateTranscript("   ", for: one.id)
        XCTAssertEqual(queue.items.first?.state, .needsReview)
        XCTAssertEqual(queue.readyCount, 0)
    }

    func testEditingDoesNotDragARowOutOfAStateThatIsNotTheUsersToChange() throws {
        let transcribing = memo(state: .transcribing, transcript: "")
        let sending = memo(state: .sending)
        try writeManifest([transcribing, sending])
        let queue = MemoQueue()
        // `.transcribing` was reset to `.awaitingModel` at launch and an edit may not move
        // it to `.ready`; the stranded send was reset to `.ready` and an edit keeps it there.
        queue.updateTranscript("new words", for: transcribing.id)
        queue.updateTranscript("new words", for: sending.id)
        XCTAssertEqual(queue.items.first(where: { $0.id == transcribing.id })?.state, .awaitingModel)
        XCTAssertEqual(queue.items.first(where: { $0.id == sending.id })?.state, .ready)
        // The text is still taken, which is what the correction path is for.
        XCTAssertEqual(queue.items.first(where: { $0.id == sending.id })?.transcript, "new words")
    }

    func testAFailedNoteCanBeTriedAgainUntilTheAttemptCapIsReached() {
        let failing = memo(state: .failed, attempts: QueuedMemo.maxAttempts - 1)
        XCTAssertTrue(failing.isSendable)
        let spent = memo(state: .failed, attempts: QueuedMemo.maxAttempts)
        XCTAssertFalse(spent.isSendable)
        // An empty task handed to an agent that can send mail is worse than no task.
        XCTAssertFalse(memo(state: .ready, transcript: "").isSendable)
        XCTAssertFalse(memo(state: .needsReview).isSendable)
        XCTAssertFalse(memo(state: .sending).isSendable)
        XCTAssertFalse(memo(state: .awaitingModel).isSendable)
    }

    func testReadyCountAndSendingCountOnlyWhatTheyName() throws {
        try writeManifest([
            memo(state: .ready), memo(state: .failed),
            memo(state: .failed, attempts: QueuedMemo.maxAttempts),
            memo(state: .needsReview, transcript: ""), memo(state: .sending),
        ])
        let queue = MemoQueue()
        XCTAssertEqual(queue.items.count, 5)
        // The ready row, the retryable failure, and the send stranded by the last kill.
        XCTAssertEqual(queue.readyCount, 3)
        XCTAssertFalse(queue.hasSendingItems)
    }

    func testDeletingAProfileTakesOnlyItsOwnNotes() throws {
        let work = memo(state: .ready, profileId: "work")
        let personal = memo(state: .ready, profileId: "personal")
        let unattributed = memo(state: .ready, profileId: nil)
        try writeManifest([work, personal, unattributed])
        let queue = MemoQueue()
        queue.purge(profileId: "work")
        XCTAssertEqual(Set(queue.items.map(\.id)), [personal.id, unattributed.id])
        // The manifest agrees, so the next launch does not resurrect the note.
        let reloaded = try JSONDecoder().decode([QueuedMemo].self, from: Data(contentsOf: manifestURL))
        XCTAssertEqual(Set(reloaded.map(\.id)), [personal.id, unattributed.id])
        queue.remove(personal.id)
        XCTAssertEqual(queue.items.map(\.id), [unattributed.id])
    }

    func testAManifestThatCannotBeDecodedLeavesAnEmptyQueueRatherThanCrashing() throws {
        try Data("not a manifest".utf8).write(to: manifestURL, options: .atomic)
        XCTAssertTrue(MemoQueue().items.isEmpty)
    }
}
