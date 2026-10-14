import FluidAudio
import Foundation
import OnnxRuntimeBindings

/// Paradee-8M (Kokoro-82M's af_heart distilled, Apache-2.0) as int8 ONNX on the CPU.
/// Model and lexicon download on first use, then it needs no network; G2P is FluidAudio's, re-contracted to Misaki.
actor ParadeeTTS {
    struct Failure: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    static let sampleRate: Double = 24_000
    private static let repo = "https://huggingface.co/sahilmahendrakar/Paradee-8M-v1.0/resolve/v1.0/"
    private static let maxPhonemes = 510
    private var session: ORTSession?
    private var vocab: [Character: Int64] = [:]
    private var phonemizer: StyleTTS2Phonemizer?

    var isReady: Bool { session != nil }

    func initialize() async throws {
        guard session == nil else { return }
        let started = Date()
        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                     appropriateFor: nil, create: true)
            .appendingPathComponent("Paradee", isDirectory: true)
        let model = try await Self.download("onnx/paradee_int8.onnx", to: directory)
        let config = try await Self.download("config.json", to: directory)
        struct Config: Decodable { let vocab: [String: Int64] }
        let entries = try JSONDecoder().decode(Config.self, from: Data(contentsOf: config)).vocab
        vocab = Dictionary(uniqueKeysWithValues: entries.compactMap { key, id in key.count == 1 ? (key.first!, id) : nil })

        try await KokoroAneResourceDownloader.ensureG2PAssets()
        guard let lexiconDirectory = await KokoroAneResourceDownloader.ensureEnglishLexicon() else {
            throw Failure(reason: "Paradee's pronunciation lexicon couldn't be downloaded.")
        }
        let lexicon = LexiconAssetCache()
        try await lexicon.ensureLoaded(kokoroDirectory: lexiconDirectory, allowedTokens: Set(entries.keys))
        let maps = await lexicon.lexicons()
        phonemizer = StyleTTS2Phonemizer(wordToPhonemes: maps.word, caseSensitiveWordToPhonemes: maps.caseSensitive)

        let options = try ORTSessionOptions()
        try options.setIntraOpNumThreads(1)
        session = try ORTSession(env: ORTEnv(loggingLevel: .warning), modelPath: model.path, sessionOptions: options)
        RealtimeLog.log("local-voice: paradee ready in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
    }

    /// One phoneme chunk per sentence (long sentences split at a space), in speaking order.
    func phonemeChunks(_ text: String) async throws -> [String] {
        guard let phonemizer else { throw Failure(reason: "Paradee isn't ready.") }
        var chunks: [String] = []
        for sentence in text.replacing(#/([.!?…])\s+/#, with: { "\($0.1)\n" }).split(separator: "\n")
        where !sentence.allSatisfy(\.isWhitespace) {
            var phonemes = Self.misaki(try await phonemizer.phonemize(String(sentence)))
            while phonemes.count > Self.maxPhonemes {
                let limit = phonemes.index(phonemes.startIndex, offsetBy: Self.maxPhonemes)
                let cut = phonemes[..<limit].lastIndex(of: " ") ?? limit
                chunks.append(String(phonemes[..<cut]))
                phonemes = String(phonemes[cut...].drop(while: { $0 == " " }))
            }
            if !phonemes.isEmpty { chunks.append(phonemes) }
        }
        return chunks
    }

    /// 24 kHz mono samples for one phoneme chunk.
    func synthesize(phonemes: String, speed: Float = 1) throws -> [Float] {
        guard let session else { throw Failure(reason: "Paradee isn't ready.") }
        let started = Date()
        var ids: [Int64] = [0] + phonemes.compactMap { vocab[$0] }.prefix(Self.maxPhonemes) + [0]
        var speed = speed
        let idsValue = try ORTValue(tensorData: NSMutableData(bytes: &ids, length: ids.count * 8),
                                    elementType: .int64, shape: [1, NSNumber(value: ids.count)])
        let speedValue = try ORTValue(tensorData: NSMutableData(bytes: &speed, length: 4), elementType: .float, shape: [1])
        let names = try session.outputNames()
        let outputs = try session.run(withInputs: ["input_ids": idsValue, "speed": speedValue],
                                      outputNames: Set(names), runOptions: nil)
        guard let name = names.first, let audio = outputs[name] else {
            throw Failure(reason: "Paradee produced no audio.")
        }
        let data = try audio.tensorData() as Data
        let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        RealtimeLog.log(String(format: "local-voice: paradee %.2fs audio in %.2fs",
                               Double(samples.count) / Self.sampleRate, Date().timeIntervalSince(started)))
        return samples
    }

    /// StyleTTS2Phonemizer expands Misaki's diphthong shorthand and spaces out punctuation;
    /// Paradee expects the original Misaki form.
    static func misaki(_ ipa: String) -> String {
        var out = ipa
        for (long, short) in [("eɪ", "A"), ("aɪ", "I"), ("oʊ", "O"), ("aʊ", "W"), ("ɔɪ", "Y")] {
            out = out.replacingOccurrences(of: long, with: short)
        }
        return out.replacing(#/ +([;:,.!?…])/#) { String($0.1) }
    }

    /// Drops near-silent samples at the end, keeping `keep` samples of tail. A phrase cut at a
    /// comma then runs straight into the next one instead of pausing as if at a full stop.
    static func trimmingTrailingSilence(_ samples: [Float], keep: Int) -> [Float] {
        guard let last = samples.lastIndex(where: { abs($0) > 0.01 }) else { return samples }
        return Array(samples.prefix(min(samples.count, last + 1 + keep)))
    }

    private static func download(_ file: String, to directory: URL) async throws -> URL {
        let destination = directory.appendingPathComponent((file as NSString).lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path) { return destination }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let (temporary, response) = try await URLSession.shared.download(from: URL(string: repo + file)!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw Failure(reason: "Paradee download failed for \(file).")
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }
}
