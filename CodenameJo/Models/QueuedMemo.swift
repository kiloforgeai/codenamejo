import Foundation

/// A spoken note waiting to become a dispatched task, kept in one JSON manifest on the phone. Its
/// id names the audio file and the job; once the dispatch log has the job, the memo is deleted.
struct QueuedMemo: Codable, Identifiable, Hashable {

    enum State: String, Codable {
        /// Recorded, but the on-device speech model isn't installed yet. Capture never blocks on
        /// the model, so a note made with no model and no network survives.
        case awaitingModel
        /// Transcription in flight. Transient: reset to `awaitingModel` on launch, since a kill
        /// never delivers a completion.
        case transcribing
        /// The recogniser produced nothing usable. Never sendable — an empty task
        /// handed to an agent that can send mail is worse than no task.
        case needsReview
        /// Has a transcript and is waiting for the user to read it and tap Send.
        case ready
        case sending
        case failed
    }

    /// **The dispatch job id.** Generated at capture, never regenerated. See the type's
    /// note — this single choice is what makes redelivery free.
    let id: UUID
    /// Filename, not a URL: the container path changes between installs and OS upgrades.
    let profileId: String?
    let filename: String
    let capturedAt: Date
    /// The zone the user was in when they spoke, so "this afternoon" resolves where it was said.
    /// Passed to `DispatchWorker` as `authoredTimeZone`.
    let capturedTimeZone: String
    var transcript: String
    var state: State
    var attempts: Int
    var lastError: String?

    var localURL: URL { MemoRecorder.directory.appendingPathComponent(filename) }

    /// Give up after this many failed sends; the note stays visible with its reason. Lives on the
    /// model so the button and the send path agree.
    static let maxAttempts = 5

    /// Whether the user can send this one now. `failed` is included because a failure here is
    /// nearly always transient.
    var isSendable: Bool {
        (state == .ready || state == .failed)
            && !transcript.isEmpty
            && attempts < Self.maxAttempts
    }

    init(id: UUID, filename: String, capturedAt: Date = Date(),
         capturedTimeZone: String = TimeZone.current.identifier,
         transcript: String = "", state: State,
         attempts: Int = 0, lastError: String? = nil, profileId: String? = nil) {
        self.profileId = profileId
        self.id = id
        self.filename = filename
        self.capturedAt = capturedAt
        self.capturedTimeZone = capturedTimeZone
        self.transcript = transcript
        self.state = state
        self.attempts = attempts
        self.lastError = lastError
    }
}
