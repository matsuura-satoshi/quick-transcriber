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
}
