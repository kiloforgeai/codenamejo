import Accelerate
import Foundation
import NaturalLanguage

/// Turns a row's text into a vector, and ranks stored vectors against a query's.
/// A linear scan on purpose: a call's lookups are a few hundred 512-float dot products.
enum ContextEmbedding {
    /// `NLEmbedding`'s sentence model is 512-dimensional for English.
    static let dimensions = 512

    /// Loaded once — `sentenceEmbedding(for:)` maps a model file in, which is not free per call.
    private static let model: NLEmbedding? = NLEmbedding.sentenceEmbedding(for: .english)

    /// The vector for `text`, L2-normalised so a dot product *is* the cosine.
    /// `nil` when the model is unavailable or the text embeds to nothing; the vector tier then does not fire.
    static func vector(for text: String) -> [Float]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let model else { return nil }
        // Sentence embedding degrades on long input and this is fed whole tool results,
        // so it sees the head — the same part `formatted` quotes back.
        guard let raw = model.vector(for: String(trimmed.prefix(1_000))) else { return nil }
        var v = raw.map(Float.init)
        var norm: Float = 0
        vDSP_svesq(v, 1, &norm, vDSP_Length(v.count))
        guard norm > 0 else { return nil }
        var scale = 1 / sqrt(norm)
        vDSP_vsmul(v, 1, &scale, &v, 1, vDSP_Length(v.count))
        return v
    }

    /// The stored form: raw little-endian `Float`s, which is what `decode` expects back.
    static func encode(_ vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// `nil` on any blob that is not a whole number of floats of the right length — a row
    /// written by an older build, or by a future one with a different model.
    static func decode(_ data: Data) -> [Float]? {
        guard data.count == dimensions * MemoryLayout<Float>.size else { return nil }
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    /// Cosine similarity of two normalised vectors, in `[-1, 1]`.
    static func similarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return -1 }
        var dot: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        return dot
    }
}
