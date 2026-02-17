import XCTest
@testable import QuickTranscriberLib

final class EmbeddingBasedSpeakerTrackerTests: XCTestCase {

    // Helper: create a normalized embedding with a dominant dimension
    private func makeEmbedding(dominant dim: Int, dimensions: Int = 256) -> [Float] {
        var v = [Float](repeating: 0.01, count: dimensions)
        v[dim] = 1.0
        return v
    }

    // MARK: - First speaker is registered and labeled

    func testFirstSpeakerGetsLabelA() {
        let tracker = EmbeddingBasedSpeakerTracker()
        let emb = makeEmbedding(dominant: 0)
        let label = tracker.identify(embedding: emb)
        XCTAssertEqual(label, "A")
    }

    // MARK: - Same speaker returns same label

    func testSameSpeakerReturnsSameLabel() {
        let tracker = EmbeddingBasedSpeakerTracker()
        let emb = makeEmbedding(dominant: 0)
        _ = tracker.identify(embedding: emb)
        let label = tracker.identify(embedding: emb)
        XCTAssertEqual(label, "A")
    }

    // MARK: - Different speaker gets new label

    func testDifferentSpeakerGetsNewLabel() {
        let tracker = EmbeddingBasedSpeakerTracker()
        _ = tracker.identify(embedding: makeEmbedding(dominant: 0))
        let label = tracker.identify(embedding: makeEmbedding(dominant: 1))
        XCTAssertEqual(label, "B")
    }

    // MARK: - Three distinct speakers

    func testThreeDistinctSpeakers() {
        let tracker = EmbeddingBasedSpeakerTracker()
        XCTAssertEqual(tracker.identify(embedding: makeEmbedding(dominant: 0)), "A")
        XCTAssertEqual(tracker.identify(embedding: makeEmbedding(dominant: 1)), "B")
        XCTAssertEqual(tracker.identify(embedding: makeEmbedding(dominant: 2)), "C")
    }

    // MARK: - Return to first speaker

    func testReturnToFirstSpeaker() {
        let tracker = EmbeddingBasedSpeakerTracker()
        let embA = makeEmbedding(dominant: 0)
        let embB = makeEmbedding(dominant: 1)
        _ = tracker.identify(embedding: embA)
        _ = tracker.identify(embedding: embB)
        let label = tracker.identify(embedding: embA)
        XCTAssertEqual(label, "A")
    }

    // MARK: - Similar embeddings match (slight variation)

    func testSimilarEmbeddingsMatchSameSpeaker() {
        let tracker = EmbeddingBasedSpeakerTracker()
        let emb1 = makeEmbedding(dominant: 0)
        _ = tracker.identify(embedding: emb1)

        // Slightly perturbed version of same speaker
        var emb2 = emb1
        emb2[1] = 0.15
        emb2[2] = 0.1
        let label = tracker.identify(embedding: emb2)
        XCTAssertEqual(label, "A")
    }

    // MARK: - Profile update (moving average)

    func testProfileUpdatesOverTime() {
        let tracker = EmbeddingBasedSpeakerTracker()
        let emb1 = makeEmbedding(dominant: 0)
        _ = tracker.identify(embedding: emb1)

        // Feed slightly drifted embedding multiple times
        var drifted = makeEmbedding(dominant: 0)
        drifted[3] = 0.3
        for _ in 0..<5 {
            let label = tracker.identify(embedding: drifted)
            XCTAssertEqual(label, "A")
        }
        // Profile should have adapted toward drifted embedding
        // Verify by checking the profile still matches drifted
        XCTAssertEqual(tracker.identify(embedding: drifted), "A")
    }

    // MARK: - Reset clears all profiles

    func testResetClearsProfiles() {
        let tracker = EmbeddingBasedSpeakerTracker()
        _ = tracker.identify(embedding: makeEmbedding(dominant: 0))
        _ = tracker.identify(embedding: makeEmbedding(dominant: 1))
        tracker.reset()
        // After reset, next speaker starts from A again
        XCTAssertEqual(tracker.identify(embedding: makeEmbedding(dominant: 2)), "A")
    }

    // MARK: - Cosine similarity helper

    func testCosineSimilarityIdentical() {
        let v = makeEmbedding(dominant: 0)
        let similarity = EmbeddingBasedSpeakerTracker.cosineSimilarity(v, v)
        XCTAssertEqual(similarity, 1.0, accuracy: 0.001)
    }

    func testCosineSimilarityOrthogonal() {
        var a = [Float](repeating: 0, count: 256)
        a[0] = 1.0
        var b = [Float](repeating: 0, count: 256)
        b[1] = 1.0
        let similarity = EmbeddingBasedSpeakerTracker.cosineSimilarity(a, b)
        XCTAssertEqual(similarity, 0.0, accuracy: 0.001)
    }

    // MARK: - Expected Speaker Count

    func testExpectedSpeakerCountLimitsNewSpeakers() {
        let tracker = EmbeddingBasedSpeakerTracker(expectedSpeakerCount: 2)
        XCTAssertEqual(tracker.identify(embedding: makeEmbedding(dominant: 0)), "A")
        XCTAssertEqual(tracker.identify(embedding: makeEmbedding(dominant: 1)), "B")
        // Third distinct voice should NOT create "C" — should assign to closest existing
        let label = tracker.identify(embedding: makeEmbedding(dominant: 2))
        XCTAssertNotEqual(label, "C", "Should not create a third speaker when limit is 2")
        XCTAssertTrue(label == "A" || label == "B", "Should assign to existing speaker")
    }

    func testExpectedSpeakerCountAssignsToBestMatch() {
        let tracker = EmbeddingBasedSpeakerTracker(expectedSpeakerCount: 2)
        _ = tracker.identify(embedding: makeEmbedding(dominant: 0))  // A
        _ = tracker.identify(embedding: makeEmbedding(dominant: 1))  // B

        // Create embedding closer to speaker A (dominant dim 0, with small contribution from dim 2)
        var closerToA = makeEmbedding(dominant: 2)
        closerToA[0] = 0.5  // Add similarity to A
        let label = tracker.identify(embedding: closerToA)
        XCTAssertEqual(label, "A", "Should assign to most similar existing speaker (A)")
    }

    func testNilExpectedSpeakerCountAllowsUnlimited() {
        let tracker = EmbeddingBasedSpeakerTracker(expectedSpeakerCount: nil)
        XCTAssertEqual(tracker.identify(embedding: makeEmbedding(dominant: 0)), "A")
        XCTAssertEqual(tracker.identify(embedding: makeEmbedding(dominant: 1)), "B")
        XCTAssertEqual(tracker.identify(embedding: makeEmbedding(dominant: 2)), "C")
        XCTAssertEqual(tracker.identify(embedding: makeEmbedding(dominant: 3)), "D")
    }

    // MARK: - Export / Load Profiles

    func testExportProfilesReturnsRegisteredSpeakers() {
        let tracker = EmbeddingBasedSpeakerTracker()
        let embA = makeEmbedding(dominant: 0)
        let embB = makeEmbedding(dominant: 1)
        _ = tracker.identify(embedding: embA)
        _ = tracker.identify(embedding: embB)

        let exported = tracker.exportProfiles()
        XCTAssertEqual(exported.count, 2)
        XCTAssertEqual(exported[0].label, "A")
        XCTAssertEqual(exported[1].label, "B")
    }

    func testLoadProfilesInitializesTracker() {
        let tracker = EmbeddingBasedSpeakerTracker()
        let embA = makeEmbedding(dominant: 0)
        let embB = makeEmbedding(dominant: 1)
        tracker.loadProfiles([
            (label: "A", embedding: embA),
            (label: "B", embedding: embB)
        ])

        let label = tracker.identify(embedding: embA)
        XCTAssertEqual(label, "A")
    }

    func testLoadProfilesNextLabelContinuesFromLoaded() {
        let tracker = EmbeddingBasedSpeakerTracker()
        tracker.loadProfiles([
            (label: "A", embedding: makeEmbedding(dominant: 0)),
            (label: "B", embedding: makeEmbedding(dominant: 1))
        ])

        let label = tracker.identify(embedding: makeEmbedding(dominant: 2))
        XCTAssertEqual(label, "C", "New speaker should get next label after loaded profiles")
    }

    func testLoadProfilesClearsExistingState() {
        let tracker = EmbeddingBasedSpeakerTracker()
        _ = tracker.identify(embedding: makeEmbedding(dominant: 0))
        _ = tracker.identify(embedding: makeEmbedding(dominant: 1))

        tracker.loadProfiles([
            (label: "X", embedding: makeEmbedding(dominant: 2))
        ])

        let exported = tracker.exportProfiles()
        XCTAssertEqual(exported.count, 1)
        XCTAssertEqual(exported[0].label, "X")
    }

    // MARK: - Profile Strategy

    func testProfileStrategyNoneIsDefault() {
        let tracker = EmbeddingBasedSpeakerTracker()
        // Default strategy should behave identically to current behavior
        XCTAssertEqual(tracker.identify(embedding: makeEmbedding(dominant: 0)), "A")
        XCTAssertEqual(tracker.identify(embedding: makeEmbedding(dominant: 1)), "B")
        XCTAssertEqual(tracker.identify(embedding: makeEmbedding(dominant: 2)), "C")
    }

    func testHitCountIncrementsOnMatch() {
        let tracker = EmbeddingBasedSpeakerTracker()
        let emb = makeEmbedding(dominant: 0)
        _ = tracker.identify(embedding: emb)  // Register A
        _ = tracker.identify(embedding: emb)  // Match A
        _ = tracker.identify(embedding: emb)  // Match A

        let profiles = tracker.exportProfiles()
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles[0].hitCount, 3)
    }

    // MARK: - Culling Strategy

    func testCullingRemovesLowHitProfiles() {
        let tracker = EmbeddingBasedSpeakerTracker(strategy: .culling(interval: 5, minHits: 2))

        let embA = makeEmbedding(dominant: 0)
        _ = tracker.identify(embedding: embA)  // Register A, hit=1
        _ = tracker.identify(embedding: embA)  // Match A, hit=2
        _ = tracker.identify(embedding: embA)  // Match A, hit=3

        _ = tracker.identify(embedding: makeEmbedding(dominant: 1))  // Register B, hit=1

        // 5th call triggers maintenance: B has hitCount=1 < minHits=2, should be culled
        _ = tracker.identify(embedding: embA)  // identifyCount=5, triggers maintenance

        let profiles = tracker.exportProfiles()
        XCTAssertEqual(profiles.count, 1, "B should have been culled")
        XCTAssertEqual(profiles[0].label, "A")
    }
}
