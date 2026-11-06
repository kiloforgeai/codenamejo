import XCTest
import GRDB
@testable import CodenameJo

final class LocalContextVectorRegressionTests: XCTestCase {
    func testRealVectorLookupHandlesEmptyMalformedAndRankedRowsWithoutChangingNotes() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        }
        let store = LocalContextStore(url: url)
        let pool = try XCTUnwrap(store.dbPool)
        let query = "Schedule a planning meeting"
        let vector = try XCTUnwrap(ContextEmbedding.vector(for: query), "The installed English model must exercise the real vector tier")
        let empty = await store.search(query, conversationId: "fixture")
        XCTAssertEqual(empty.matched, .recency)
        XCTAssertTrue(empty.rows.isEmpty)
        XCTAssertEqual(LocalContextStore.vectorDiagnostic(count: 0, best: nil),
                       "localContext: vector scanned 0, best 0.000, floor 0.55")

        try await pool.write { db in
            var malformed = LocalContextRow(key: "m_1", kind: "note", request: "fixture-invalid",
                result: "preserved body", summary: "", conversationId: "fixture", embedding: Data([1, 2, 3]), createdAt: Date())
            try malformed.insert(db)
        }
        let malformed = await store.search(query, conversationId: "fixture")
        XCTAssertEqual(malformed.matched, .recency)
        XCTAssertEqual(malformed.rows.map(\.key), ["m_1"])

        try await pool.write { db in
            for (key, scoreVector) in [("m_2", vector), ("m_3", vector.map { -$0 })] {
                var row = LocalContextRow(key: key, kind: "note", request: "fixture-\(key)",
                    result: "preserved body", summary: "", conversationId: "fixture",
                    embedding: ContextEmbedding.encode(scoreVector), createdAt: Date())
                try row.insert(db)
            }
        }
        let ranked = await store.search(query, conversationId: "fixture")
        XCTAssertEqual(ranked.matched, .vector)
        XCTAssertEqual(ranked.rows.map(\.key), ["m_2"])
        let score = ContextEmbedding.similarity(vector, vector)
        XCTAssertEqual(LocalContextStore.vectorDiagnostic(count: 2, best: score),
                       "localContext: vector scanned 2, best 1.000, floor 0.55")
        let receipt = await store.save(request: "Archive feedback", result: "Use the selected item.",
            summary: "", kind: "note", conversationId: "fixture")
        XCTAssertEqual(receipt, "Cached as m_4.")
        let note = await store.row(key: "m_4", in: "fixture")
        XCTAssertEqual(note?.result, "Use the selected item.")
        let original = await store.row(key: "m_2", in: "fixture")
        XCTAssertEqual(original?.result, "preserved body")
        XCTAssertEqual(original?.embedding, ContextEmbedding.encode(vector))
    }
}
