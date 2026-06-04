import XCTest
@testable import QuickTranscriberLib

final class ConfusionPairAnalysisTests: XCTestCase {
    /// Standing roster of regulars present in the production store (see plan roster assumption).
    static let roster = ["松浦", "今村", "上東", "森", "森谷", "神野"]
    static let productionProfilePath = NSString(string: "~/QuickTranscriber/speakers.json").expandingTildeInPath

    struct RosterSimilarityArtifact: Codable {
        let speakers: [String]
        let matrix: [[Float]]          // matrix[i][j] = cos(speakers[i], speakers[j])
        let topPairs: [Pair]           // sorted descending, i<j
        struct Pair: Codable { let a: String; let b: String; let similarity: Float }
    }

    func testStaticRosterSimilarity() throws {
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: Self.productionProfilePath),
            "production speakers.json not present"
        )
        let profiles = try SpeakerProfileLoader.load(
            path: Self.productionProfilePath,
            displayNames: Self.roster
        )
        // Preserve roster order for a stable matrix.
        let ordered = Self.roster.compactMap { name in profiles.first { $0.displayName == name } }
        XCTAssertEqual(ordered.count, Self.roster.count)

        var matrix = [[Float]](repeating: [Float](repeating: 0, count: ordered.count), count: ordered.count)
        var pairs: [RosterSimilarityArtifact.Pair] = []
        for i in 0..<ordered.count {
            for j in 0..<ordered.count {
                let sim = EmbeddingBasedSpeakerTracker.cosineSimilarity(ordered[i].embedding, ordered[j].embedding)
                matrix[i][j] = sim
                if i < j {
                    pairs.append(.init(a: ordered[i].displayName, b: ordered[j].displayName, similarity: sim))
                }
            }
        }
        pairs.sort { $0.similarity > $1.similarity }

        // Invariants
        for i in 0..<ordered.count {
            XCTAssertEqual(matrix[i][i], 1.0, accuracy: 0.01, "diagonal must be 1")
            for j in 0..<ordered.count {
                XCTAssertEqual(matrix[i][j], matrix[j][i], accuracy: 1e-5, "matrix must be symmetric")
            }
        }
        // Pre-registered finding: 神野 is within the top similarity neighbourhood of an active speaker.
        let kaminoToUehigashi = simBetween(matrix, ordered, "神野", "上東")
        let kaminoToMori = simBetween(matrix, ordered, "神野", "森")
        XCTAssertGreaterThan(kaminoToUehigashi, 0.70, "神野 should be close to 上東 (observed ~0.764)")
        XCTAssertGreaterThan(kaminoToMori, 0.70, "神野 should be close to 森 (observed ~0.768)")

        let artifact = RosterSimilarityArtifact(
            speakers: ordered.map(\.displayName), matrix: matrix, topPairs: pairs
        )
        let outURL = URL(fileURLWithPath: "/tmp/confusion_roster_similarity.json")
        try JSONEncoder().encode(artifact).write(to: outURL, options: .atomic)
        NSLog("[ConfusionPair] roster similarity written: \(outURL.path)")
        for p in pairs.prefix(6) {
            NSLog("[ConfusionPair] pair \(p.a)<->\(p.b): \(String(format: "%.3f", p.similarity))")
        }
    }

    private func simBetween(_ m: [[Float]], _ ordered: [LoadedSpeakerProfile], _ a: String, _ b: String) -> Float {
        guard let i = ordered.firstIndex(where: { $0.displayName == a }),
              let j = ordered.firstIndex(where: { $0.displayName == b }) else { return 0 }
        return m[i][j]
    }
}
