import XCTest
@testable import QuickTranscriberLib

final class EmbeddingMathTests: XCTestCase {

    // MARK: - cosineSimilarity

    func testCosineIdenticalVectorsIsOne() {
        XCTAssertEqual(EmbeddingMath.cosineSimilarity([1, 2, 3], [1, 2, 3]), 1.0, accuracy: 1e-6)
    }

    func testCosineOrthogonalVectorsIsZero() {
        XCTAssertEqual(EmbeddingMath.cosineSimilarity([1, 0], [0, 1]), 0.0, accuracy: 1e-6)
    }

    func testCosineMismatchedDimensionsReturnsZero() {
        XCTAssertEqual(EmbeddingMath.cosineSimilarity([1, 2], [1, 2, 3]), 0)
    }

    func testCosineEmptyVectorsReturnsZero() {
        XCTAssertEqual(EmbeddingMath.cosineSimilarity([], []), 0)
    }

    func testCosineZeroVectorReturnsZero() {
        XCTAssertEqual(EmbeddingMath.cosineSimilarity([0, 0], [1, 1]), 0)
    }

    // MARK: - weightedMean

    func testWeightedMeanSingleItemReturnsItself() {
        let result = EmbeddingMath.weightedMean([(embedding: [1, 2, 3], weight: 0.7)])
        XCTAssertEqual(result!, [1, 2, 3])
    }

    func testWeightedMeanTwoItemsExactValues() {
        // (3*[1,0] + 1*[0,1]) / 4 = [0.75, 0.25]
        let result = EmbeddingMath.weightedMean([
            (embedding: [1, 0], weight: 3),
            (embedding: [0, 1], weight: 1),
        ])!
        XCTAssertEqual(result[0], 0.75, accuracy: 1e-6)
        XCTAssertEqual(result[1], 0.25, accuracy: 1e-6)
    }

    func testWeightedMeanSkipsMismatchedDimensions() {
        // 次元不一致エントリはスキップ（engine の旧 centroid と同じ防御挙動）
        let result = EmbeddingMath.weightedMean([
            (embedding: [1, 0], weight: 1),
            (embedding: [9, 9, 9], weight: 100),
        ])!
        XCTAssertEqual(result, [1, 0])
    }

    func testWeightedMeanEmptyReturnsNil() {
        XCTAssertNil(EmbeddingMath.weightedMean([]))
    }

    func testWeightedMeanZeroTotalWeightReturnsNil() {
        XCTAssertNil(EmbeddingMath.weightedMean([(embedding: [1, 2], weight: 0)]))
    }

    // MARK: - blend

    func testBlendAlphaZeroReturnsFirst() {
        XCTAssertEqual(EmbeddingMath.blend([1, 2], [5, 6], alpha: 0), [1, 2])
    }

    func testBlendAlphaOneReturnsSecond() {
        XCTAssertEqual(EmbeddingMath.blend([1, 2], [5, 6], alpha: 1), [5, 6])
    }

    func testBlendExactValues() {
        // (1-0.25)*[4,0] + 0.25*[0,4] = [3, 1]
        let result = EmbeddingMath.blend([4, 0], [0, 4], alpha: 0.25)
        XCTAssertEqual(result[0], 3, accuracy: 1e-6)
        XCTAssertEqual(result[1], 1, accuracy: 1e-6)
    }
}
