import XCTest
@testable import QuickTranscriberLib

final class EmbeddingHistoryStoreTests: XCTestCase {

    private func makeTempDirectory() -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmbeddingHistoryStoreTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    private func makeEmbedding(dominant dim: Int, dimensions: Int = 256) -> [Float] {
        var v = [Float](repeating: 0.01, count: dimensions)
        v[dim] = 1.0
        return v
    }

    func testAppendAndLoad() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = EmbeddingHistoryStore(directory: dir)
        let entry = EmbeddingHistoryEntry(
            speakerProfileId: UUID(),
            label: "A",
            sessionDate: Date(),
            embeddings: [
                HistoricalEmbedding(embedding: makeEmbedding(dominant: 0), confirmed: true)
            ]
        )
        store.appendSession(entries: [entry])

        let store2 = EmbeddingHistoryStore(directory: dir)
        let loaded = try store2.loadAll()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].label, "A")
        XCTAssertEqual(loaded[0].embeddings.count, 1)
        XCTAssertTrue(loaded[0].embeddings[0].confirmed)
    }

    func testMultipleSessionsAccumulate() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = EmbeddingHistoryStore(directory: dir)
        let id = UUID()

        store.appendSession(entries: [
            EmbeddingHistoryEntry(speakerProfileId: id, label: "A", sessionDate: Date(),
                                 embeddings: [HistoricalEmbedding(embedding: makeEmbedding(dominant: 0), confirmed: true)])
        ])
        store.appendSession(entries: [
            EmbeddingHistoryEntry(speakerProfileId: id, label: "A", sessionDate: Date(),
                                 embeddings: [HistoricalEmbedding(embedding: makeEmbedding(dominant: 1), confirmed: true)])
        ])

        let loaded = try store.loadAll()
        XCTAssertEqual(loaded.count, 2)
    }

    func testReconstructProfile() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = EmbeddingHistoryStore(directory: dir)
        let id = UUID()
        let emb1 = makeEmbedding(dominant: 0)
        let emb2 = makeEmbedding(dominant: 0)

        store.appendSession(entries: [
            EmbeddingHistoryEntry(speakerProfileId: id, label: "A", sessionDate: Date(),
                                 embeddings: [
                                    HistoricalEmbedding(embedding: emb1, confirmed: true),
                                    HistoricalEmbedding(embedding: emb2, confirmed: true),
                                 ])
        ])

        let reconstructed = try store.reconstructProfile(for: id)
        XCTAssertNotNil(reconstructed)
        let expected = zip(emb1, emb2).map { ($0 + $1) / 2 }
        for i in 0..<expected.count {
            XCTAssertEqual(reconstructed![i], expected[i], accuracy: 0.001)
        }
    }

    func testReconstructUnknownProfileReturnsNil() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = EmbeddingHistoryStore(directory: dir)
        let result = try store.reconstructProfile(for: UUID())
        XCTAssertNil(result)
    }

    func testLoadFromNonexistentFileReturnsEmpty() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = EmbeddingHistoryStore(directory: dir)
        let loaded = try store.loadAll()
        XCTAssertTrue(loaded.isEmpty)
    }

    func testReconstructProfileIgnoresUnconfirmedEmbeddings() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = EmbeddingHistoryStore(directory: dir)
        let id = UUID()

        store.appendSession(entries: [
            EmbeddingHistoryEntry(speakerProfileId: id, label: "A", sessionDate: Date(),
                                 embeddings: [
                                    HistoricalEmbedding(embedding: makeEmbedding(dominant: 0), confirmed: true),
                                    HistoricalEmbedding(embedding: makeEmbedding(dominant: 5), confirmed: false),
                                 ])
        ])

        let reconstructed = try store.reconstructProfile(for: id)
        XCTAssertNotNil(reconstructed)
        // Only the confirmed embedding (dominant dim 0) should be used
        XCTAssertEqual(reconstructed![0], 1.0, accuracy: 0.001)
        XCTAssertEqual(reconstructed![5], 0.01, accuracy: 0.001)
    }

    func testReconstructProfileAllUnconfirmedReturnsNil() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = EmbeddingHistoryStore(directory: dir)
        let id = UUID()

        store.appendSession(entries: [
            EmbeddingHistoryEntry(speakerProfileId: id, label: "A", sessionDate: Date(),
                                 embeddings: [
                                    HistoricalEmbedding(embedding: makeEmbedding(dominant: 0), confirmed: false),
                                 ])
        ])

        let result = try store.reconstructProfile(for: id)
        XCTAssertNil(result)
    }

    func testReconstructProfileAcrossMultipleSessions() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = EmbeddingHistoryStore(directory: dir)
        let id = UUID()

        // Session 1: embedding with dominant dim 0
        store.appendSession(entries: [
            EmbeddingHistoryEntry(speakerProfileId: id, label: "A", sessionDate: Date(),
                                 embeddings: [HistoricalEmbedding(embedding: makeEmbedding(dominant: 0), confirmed: true)])
        ])
        // Session 2: embedding with dominant dim 1
        store.appendSession(entries: [
            EmbeddingHistoryEntry(speakerProfileId: id, label: "A", sessionDate: Date(),
                                 embeddings: [HistoricalEmbedding(embedding: makeEmbedding(dominant: 1), confirmed: true)])
        ])

        let reconstructed = try store.reconstructProfile(for: id)
        XCTAssertNotNil(reconstructed)
        // Average of two embeddings: dim 0 and dim 1 should both be (1.0 + 0.01) / 2
        XCTAssertEqual(reconstructed![0], (1.0 + 0.01) / 2, accuracy: 0.001)
        XCTAssertEqual(reconstructed![1], (0.01 + 1.0) / 2, accuracy: 0.001)
    }

    func testHistoricalEmbeddingCodable() throws {
        let original = HistoricalEmbedding(embedding: makeEmbedding(dominant: 3), confirmed: true)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(HistoricalEmbedding.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func testEmbeddingHistoryEntryCodable() throws {
        let original = EmbeddingHistoryEntry(
            speakerProfileId: UUID(),
            label: "B",
            sessionDate: Date(timeIntervalSince1970: 1000),
            embeddings: [
                HistoricalEmbedding(embedding: makeEmbedding(dominant: 0), confirmed: true),
                HistoricalEmbedding(embedding: makeEmbedding(dominant: 1), confirmed: false),
            ]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(EmbeddingHistoryEntry.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func testHistoricalEmbeddingBackwardCompatibility() throws {
        // JSON without confidence field (legacy format)
        let json = """
        {"embedding":[1.0,0.0,0.0],"confirmed":true}
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(HistoricalEmbedding.self, from: data)
        XCTAssertEqual(decoded.embedding, [1.0, 0.0, 0.0])
        XCTAssertTrue(decoded.confirmed)
        XCTAssertNil(decoded.confidence)
    }

    func testHistoricalEmbeddingWithConfidence() throws {
        let original = HistoricalEmbedding(embedding: [1.0, 0.0], confirmed: true, confidence: 0.85)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(HistoricalEmbedding.self, from: data)
        XCTAssertEqual(decoded.confidence, 0.85)
    }

    func testReconstructProfileWeightedMean() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = EmbeddingHistoryStore(directory: dir)
        let id = UUID()
        // High confidence embedding: dominant dim 0
        let emb1 = makeEmbedding(dominant: 0)
        // Low confidence embedding: dominant dim 1
        let emb2 = makeEmbedding(dominant: 1)

        store.appendSession(entries: [
            EmbeddingHistoryEntry(speakerProfileId: id, label: "A", sessionDate: Date(),
                                 embeddings: [
                                    HistoricalEmbedding(embedding: emb1, confirmed: true, confidence: 0.9),
                                    HistoricalEmbedding(embedding: emb2, confirmed: true, confidence: 0.3),
                                 ])
        ])

        let reconstructed = try store.reconstructProfile(for: id)
        XCTAssertNotNil(reconstructed)
        // Weighted: (0.9 * emb1 + 0.3 * emb2) / 1.2
        let expected0 = (0.9 * emb1[0] + 0.3 * emb2[0]) / 1.2
        let expected1 = (0.9 * emb1[1] + 0.3 * emb2[1]) / 1.2
        XCTAssertEqual(reconstructed![0], expected0, accuracy: 0.001)
        XCTAssertEqual(reconstructed![1], expected1, accuracy: 0.001)
    }

    func testReconstructProfileLegacyWithoutConfidence() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = EmbeddingHistoryStore(directory: dir)
        let id = UUID()
        let emb1 = makeEmbedding(dominant: 0)
        let emb2 = makeEmbedding(dominant: 1)

        // Entries without confidence (nil) should default to weight 1.0
        store.appendSession(entries: [
            EmbeddingHistoryEntry(speakerProfileId: id, label: "A", sessionDate: Date(),
                                 embeddings: [
                                    HistoricalEmbedding(embedding: emb1, confirmed: true),
                                    HistoricalEmbedding(embedding: emb2, confirmed: true),
                                 ])
        ])

        let reconstructed = try store.reconstructProfile(for: id)
        XCTAssertNotNil(reconstructed)
        // Both have weight 1.0 → arithmetic mean
        let expected = zip(emb1, emb2).map { ($0 + $1) / 2 }
        for i in 0..<expected.count {
            XCTAssertEqual(reconstructed![i], expected[i], accuracy: 0.001)
        }
    }
}
