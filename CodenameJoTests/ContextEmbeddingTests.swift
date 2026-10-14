import XCTest
@testable import CodenameJo

/// The vector tier of the on-device context store: how a vector is stored, how a stored one
/// is read back, and what happens to a blob written by a build that is not this one.
///
/// `decode` is the boundary that matters. A row from an older build, or a future one with a
/// different model, is a `Data` of the wrong length — and a decode that guessed instead of
/// refusing would hand `similarity` two arrays it would rank against each other anyway.
final class ContextEmbeddingTests: XCTestCase {

    /// A deterministic stand-in for a model vector — no `NLEmbedding` involved, so this runs
    /// the same wherever `xcodebuild` puts it.
    private func vector(seed: Float) -> [Float] {
        (0..<ContextEmbedding.dimensions).map { seed + Float($0) / 1000 }
    }

    // MARK: - Storage round trip

    func testAStoredVectorComesBackTheSameFloats() {
        let original = vector(seed: 0.25)
        let decoded = ContextEmbedding.decode(ContextEmbedding.encode(original))

        XCTAssertEqual(decoded, original)
    }

    func testAVectorOccupiesExactlyFourBytesPerDimension() {
        XCTAssertEqual(
            ContextEmbedding.encode(vector(seed: 0)).count,
            ContextEmbedding.dimensions * MemoryLayout<Float>.size)
    }

    // MARK: - Blobs this build did not write

    func testABlobOfTheWrongLengthIsRefusedRatherThanReinterpreted() {
        let short = ContextEmbedding.encode(Array(vector(seed: 1).dropLast()))
        let long = ContextEmbedding.encode(vector(seed: 1) + [0])

        XCTAssertNil(ContextEmbedding.decode(short), "a 511-float row is not this model's")
        XCTAssertNil(ContextEmbedding.decode(long), "and neither is a 513-float one")
        XCTAssertNil(ContextEmbedding.decode(Data()), "an empty column is not a vector")
    }

    func testAPartialFloatIsNotRoundedIntoAVector() {
        var truncated = ContextEmbedding.encode(vector(seed: 1))
        truncated.removeLast()
        XCTAssertNil(ContextEmbedding.decode(truncated))
    }

    // MARK: - Ranking

    func testAVectorIsPerfectlySimilarToItself() {
        var unit = [Float](repeating: 0, count: ContextEmbedding.dimensions)
        unit[0] = 1
        XCTAssertEqual(ContextEmbedding.similarity(unit, unit), 1, accuracy: 1e-5)
    }

    func testTwoVectorsSharingNoDirectionScoreZero() {
        var first = [Float](repeating: 0, count: ContextEmbedding.dimensions)
        var second = first
        first[0] = 1
        second[1] = 1

        XCTAssertEqual(ContextEmbedding.similarity(first, second), 0, accuracy: 1e-5)
    }

    func testAnOppositeVectorScoresTheFloorRatherThanTheCeiling() {
        var forward = [Float](repeating: 0, count: ContextEmbedding.dimensions)
        forward[0] = 1
        let back = forward.map { -$0 }

        XCTAssertEqual(ContextEmbedding.similarity(forward, back), -1, accuracy: 1e-5)
    }

    /// Mismatched lengths cannot be ranked, and the answer has to sort below every real
    /// comparison rather than above them.
    func testVectorsOfDifferentLengthsRankBelowEverythingComparable() {
        let full = vector(seed: 0)
        let stub: [Float] = [1, 0, 0]

        XCTAssertEqual(ContextEmbedding.similarity(full, stub), -1)
        XCTAssertEqual(ContextEmbedding.similarity(stub, full), -1)
    }

    // MARK: - Text with nothing in it

    func testTextWithNoWordsInItEmbedsToNothing() {
        XCTAssertNil(ContextEmbedding.vector(for: ""))
        XCTAssertNil(ContextEmbedding.vector(for: "   \n\t "))
    }
}
