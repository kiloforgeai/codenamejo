import AVFoundation
import Foundation
import Speech

/// Turns a finished memo file into text on the device with `SpeechAnalyzer`; Apple hosts the model via `AssetInventory`.
/// `SpeechAnalyzer` needs no speech-recognition authorization or usage-description key, only the microphone.
@MainActor
final class MemoTranscriber: ObservableObject {

    /// Whether this device can transcribe a memo right now, modelled on `AssetInventory.Status`.
    enum Readiness: Equatable {
        /// Not yet checked, as opposed to checked and absent (`notInstalled`).
        case unknown
        case ready
        /// Supported here, but the assets need a download — which needs a network.
        case notInstalled
        case installing(Double)
        /// No model for this language, and no download will change that.
        case unsupportedLocale(String)
        /// `SpeechTranscriber.isAvailable` is false, or a check threw.
        case failed(String)

        var canTranscribe: Bool { self == .ready }
    }

    enum Failure: LocalizedError {
        case modelUnavailable
        /// The analyzer ran and produced nothing; a case of its own so it never becomes an empty task.
        case empty
        case analyzer(Error)

        var errorDescription: String? {
            switch self {
            case .modelUnavailable: "The offline speech model isn't installed yet."
            case .empty: "Nothing was said, or it couldn't be made out."
            case .analyzer(let error): error.localizedDescription
            }
        }
    }

    @Published private(set) var readiness: Readiness = .unknown

    /// The locale the model runs in, once resolved; `en-US` when the user's own has no model.
    private(set) var locale = Locale(identifier: "en-US")

    private var resolvedLocale = false

    // MARK: - Model readiness

    /// Make sure the model is installed and reserved. Idempotent; needs a network only the
    /// first time, and failing only delays transcription.
    func ensureModel() async {
        guard readiness != .ready else { return }

        guard SpeechTranscriber.isAvailable else {
            set(.failed("Speech recognition isn't available on this device."))
            return
        }

        do {
            try await resolveLocaleIfNeeded()
        } catch {
            set(.failed(error.localizedDescription))
            return
        }

        guard resolvedLocale else { return }

        let transcriber = makeTranscriber()

        switch await AssetInventory.status(forModules: [transcriber]) {
        case .installed:
            await reserve()
            set(.ready)
            return
        case .unsupported:
            set(.unsupportedLocale(locale.identifier(.bcp47)))
            return
        case .downloading, .supported:
            break
        @unknown default:
            break
        }

        set(.notInstalled)

        do {
            // Nil means nothing to fetch: system dictation uses the same assets.
            guard let request = try await AssetInventory
                .assetInstallationRequest(supporting: [transcriber])
            else {
                await reserve()
                set(.ready)
                return
            }

            set(.installing(0))
            let progress = request.progress
            // Polls `Progress` rather than observing it via KVO, which would need teardown on every path.
            let ticker = Task { [weak self] in
                while !Task.isCancelled {
                    let fraction = progress.fractionCompleted
                    await MainActor.run { self?.set(.installing(fraction)) }
                    try? await Task.sleep(for: .milliseconds(400))
                }
            }
            defer { ticker.cancel() }

            try await request.downloadAndInstall()
            await reserve()
            set(.ready)
            RealtimeLog.log("memos: speech model installed for \(locale.identifier(.bcp47))")
        } catch {
            // Surfaced, never swallowed, so an install failure is visible in Settings.
            set(.failed(error.localizedDescription))
            RealtimeLog.log("memos: speech model install failed — \(error.localizedDescription)")
        }
    }

    /// Hold onto the locale's assets so the system cannot reclaim them; offline, a reclaimed
    /// model cannot be downloaded again.
    private func reserve() async {
        do {
            let already = await AssetInventory.reservedLocales
            guard !already.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) })
            else { return }

            // The reservation cap is small and shared across the device.
            if already.count >= AssetInventory.maximumReservedLocales,
               let oldest = already.first {
                await AssetInventory.release(reservedLocale: oldest)
            }
            try await AssetInventory.reserve(locale: locale)
        } catch {
            // Not fatal: the model works, it just might not survive a storage squeeze.
            RealtimeLog.log("memos: could not reserve \(locale.identifier(.bcp47)) — "
                + error.localizedDescription)
        }
    }

    /// Pick the locale to transcribe in, once. Matches on `identifier(.bcp47)`: comparing
    /// `Locale` with `==` silently fails on region or variant differences.
    private func resolveLocaleIfNeeded() async throws {
        guard !resolvedLocale else { return }

        let supported = await SpeechTranscriber.supportedLocales
        func isSupported(_ candidate: Locale) -> Bool {
            supported.contains { $0.identifier(.bcp47) == candidate.identifier(.bcp47) }
        }

        if let match = await SpeechTranscriber.supportedLocale(equivalentTo: .current) {
            locale = match
        } else if isSupported(.current) {
            locale = .current
        } else {
            locale = Locale(identifier: "en-US")
            guard isSupported(locale) else {
                set(.unsupportedLocale(Locale.current.identifier(.bcp47)))
                return
            }
        }

        resolvedLocale = true
        RealtimeLog.log("memos: transcribing in \(locale.identifier(.bcp47))")
    }

    // MARK: - Transcription

    /// Transcribe a finished recording. Throws rather than returning an empty string.
    func transcribe(fileAt url: URL) async throws -> String {
        await ensureModel()
        guard readiness.canTranscribe else { throw Failure.modelUnavailable }

        let transcriber = makeTranscriber()
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        do {
            let file = try AVAudioFile(forReading: url)

            // Collect before analysing: `results` is live, so starting later loses early segments.
            let collected = Task {
                var pieces: [String] = []
                for try await result in transcriber.results {
                    pieces.append(String(result.text.characters))
                }
                return pieces.joined()
            }

            _ = try await analyzer.analyzeSequence(from: file)
            try await analyzer.finalizeAndFinishThroughEndOfInput()

            let text = try await collected.value
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw Failure.empty }
            return text
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.analyzer(error)
        }
    }

    // MARK: - Helpers

    /// Built fresh per use: a `SpeechAnalyzer` consumes its modules for one run. No volatile
    /// results, so every result is final and concatenating them is correct.
    private func makeTranscriber() -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [])
    }

    private func set(_ next: Readiness) {
        guard readiness != next else { return }
        readiness = next
    }
}
