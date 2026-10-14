import AVFoundation
import FactoryKit
import Foundation

/// Captures a spoken note to a file with `AVAudioEngine`, with no network and no call.
/// Uses bare `AVAudioSession` (safe only because no call can be live); blocking CoreAudio work runs on `AudioQueue`.
@MainActor
final class MemoRecorder: ObservableObject {

    enum Refusal: LocalizedError {
        /// A call is up; two AudioUnit input clients on one session is not supported.
        case callIsLive
        /// A second `start` while one is running, e.g. a double-tap.
        case alreadyRecording
        case file(Error)

        var errorDescription: String? {
            switch self {
            case .callIsLive: "Finish the call before leaving a note."
            case .alreadyRecording: "Already recording."
            case .file(let error): "Couldn't start recording — \(error.localizedDescription)"
            }
        }
    }

    /// Below this, it was a mis-tap; a safety rule, since every note becomes a dispatch job that can send mail.
    static let minimumDuration: TimeInterval = 0.7

    /// A forgotten open microphone is the failure this bounds.
    static let maximumDuration: TimeInterval = 120

    /// Where memos live. Excluded from backup so a restored phone does not replay stale tasks.
    nonisolated static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceMemos", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        var resources = URLResourceValues()
        resources.isExcludedFromBackup = true
        var mutable = base
        try? mutable.setResourceValues(resources)
        return base
    }

    @Published private(set) var isRecording = false

    /// Seconds captured so far, republished twice a second while recording.
    @Published private(set) var elapsed: TimeInterval = 0

    /// A recording stopped by the `maximumDuration` cap, which no caller holds yet.
    /// The observer clears it once the note is queued.
    @Published var unclaimedURL: URL?

    private var startedAt: Date?
    private var ticker: Task<Void, Never>?

    @Injected(\.realtimeService) private var realtime

    /// Touched only inside serial `queue` closures and on CoreAudio's render thread.
    private nonisolated(unsafe) var engine: AVAudioEngine?
    private nonisolated(unsafe) var file: AVAudioFile?
    private nonisolated(unsafe) var converter: AVAudioConverter?
    private let queue = AudioQueue()

    // MARK: - Lifecycle

    /// Open the microphone and start writing to `<id>.m4a`. The caller handles mic permission.
    private(set) var capturedProfileId: String?

    @discardableResult
    func start(id: UUID) async throws -> URL {
        guard !realtime.isConversing else {
            RealtimeLog.log("memos: refused to record — a call is live")
            throw Refusal.callIsLive
        }
        guard !isRecording else { throw Refusal.alreadyRecording }
        capturedProfileId = ProfileRuntime.snapshot?.profileId

        let url = Self.directory.appendingPathComponent("\(id.uuidString).m4a")
        try? FileManager.default.removeItem(at: url)

        do {
            try await queue.run("memo record start") { [weak self] in
                let session = AVAudioSession.sharedInstance()
                // Explicit every time: a finished call leaves `.playAndRecord` / `.videoChat` behind.
                try session.setCategory(.record, mode: .default, options: [.allowBluetooth])
                try session.setActive(true)
                try? session.setAllowHapticsAndSystemSoundsDuringRecording(true)

                // After the session is configured, never before: `inputNode` throws if
                // the category does not permit recording.
                let engine = AVAudioEngine()
                let input = engine.inputNode
                let hardware = input.outputFormat(forBus: 0)
                guard hardware.sampleRate > 0 else {
                    throw Refusal.file(NSError(
                        domain: "memos", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "The microphone reported no format."]))
                }

                // The hardware's rate, so the only conversion is to mono. No `AVEncoderBitRateKey`:
                // a fixed rate can be invalid for AAC-LC mono at 48 kHz ('!dat'), so the encoder picks.
                let settings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: hardware.sampleRate,
                    AVNumberOfChannelsKey: 1,
                ]
                let file = try AVAudioFile(forWriting: url, settings: settings)
                // Logs the negotiated format, which is what makes format failures diagnosable.
                RealtimeLog.log(String(
                    format: "memos: capturing %.0f Hz %dch -> %.0f Hz mono aac",
                    hardware.sampleRate, hardware.channelCount,
                    file.processingFormat.sampleRate))

                // Hardware PCM to the file's `processingFormat`: same rate, so a channel mix only.
                let converter = AVAudioConverter(from: hardware, to: file.processingFormat)

                input.installTap(onBus: 0, bufferSize: 4096, format: hardware) { buffer, _ in
                    // On CoreAudio's render thread. Touch nothing here that is not
                    // already confined to it — no `@Published`, no main actor.
                    guard let self else { return }
                    self.write(buffer)
                }

                engine.prepare()
                try engine.start()

                self?.engine = engine
                self?.file = file
                self?.converter = converter
            }
        } catch let refusal as Refusal {
            await teardown()
            throw refusal
        } catch {
            await teardown()
            throw Refusal.file(error)
        }

        isRecording = true
        startedAt = Date()
        elapsed = 0
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, let startedAt = self.startedAt else { return }
                let running = Date().timeIntervalSince(startedAt)
                guard running < Self.maximumDuration else {
                    // The cap: closes the mic and leaves the note in `unclaimedURL`.
                    self.elapsed = Self.maximumDuration
                    if let finished = await self.stop() {
                        self.unclaimedURL = finished
                    }
                    return
                }
                self.elapsed = running
            }
        }
        RealtimeLog.log("memos: recording \(url.lastPathComponent)")
        return url
    }

    /// Close the file and hand it back, or `nil` (with the audio deleted) if there is nothing worth keeping.
    func stop() async -> URL? {
        guard isRecording else { return nil }
        isRecording = false
        let onTheClock = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        startedAt = nil
        elapsed = 0
        ticker?.cancel()
        ticker = nil

        // Duration from frames written, not the wall clock, so an empty file never passes as a note.
        let captured = try? await queue.run("memo record stop") { [weak self] () -> (URL, TimeInterval)? in
            guard let file = self?.file else { return nil }
            let url = file.url
            let seconds = file.length > 0
                ? Double(file.length) / file.processingFormat.sampleRate
                : 0
            return (url, seconds)
        }

        await teardown()

        guard let (url, seconds) = captured ?? nil else {
            RealtimeLog.log("memos: stop found no open file")
            return nil
        }

        guard seconds >= Self.minimumDuration else {
            try? FileManager.default.removeItem(at: url)
            RealtimeLog.log(String(
                format: "memos: discarded %.2fs of audio (mic was open %.1fs)",
                seconds, onTheClock))
            return nil
        }

        RealtimeLog.log(String(format: "memos: recorded %.1fs to %@", seconds, url.lastPathComponent))
        return url
    }

    // MARK: - Writing

    /// Called on CoreAudio's render thread, once per buffer. Silent on failure: `stop()`
    /// counts frames written, so dropped buffers show up as a short recording.
    private nonisolated func write(_ buffer: AVAudioPCMBuffer) {
        guard let file, let converter else { return }

        let target = file.processingFormat
        guard let converted = AVAudioPCMBuffer(
            pcmFormat: target,
            frameCapacity: buffer.frameLength)
        else { return }

        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, converted.frameLength > 0 else { return }
        try? file.write(from: converted)
    }

    // MARK: - Helpers

    /// Tear the graph down and hand the session back. Setting `file` to nil finalises the
    /// m4a: `AVAudioFile` writes its `moov` atom on deallocation.
    private func teardown() async {
        _ = try? await queue.run("memo record teardown") { [weak self] in
            if let engine = self?.engine {
                engine.inputNode.removeTap(onBus: 0)
                engine.stop()
            }
            self?.engine = nil
            self?.converter = nil
            self?.file = nil
            try? AVAudioSession.sharedInstance()
                .setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}
