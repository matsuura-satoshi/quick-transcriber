import XCTest
@testable import QuickTranscriberLib

final class DiarizationMetricsTests: XCTestCase {

    func testPerfectPrediction() {
        let groundTruth = Array(repeating: "A", count: 5) + Array(repeating: "B", count: 5)
        let predicted = Array(repeating: "X", count: 5) + Array(repeating: "Y", count: 5)

        let metrics = DiarizationMetrics.compute(
            groundTruth: groundTruth,
            predicted: predicted
        )

        XCTAssertEqual(metrics.chunkAccuracy, 1.0)
        XCTAssertEqual(metrics.speakerCountCorrect, true)
    }

    func testSwappedLabels() {
        let groundTruth = ["A", "A", "B", "B"]
        let predicted = ["B", "B", "A", "A"]

        let metrics = DiarizationMetrics.compute(
            groundTruth: groundTruth,
            predicted: predicted
        )

        XCTAssertEqual(metrics.chunkAccuracy, 1.0)
    }

    func testHalfWrong() {
        let groundTruth = ["A", "A", "B", "B"]
        let predicted = ["X", "X", "X", "Y"]

        let metrics = DiarizationMetrics.compute(
            groundTruth: groundTruth,
            predicted: predicted
        )

        XCTAssertEqual(metrics.chunkAccuracy, 0.75)
    }

    func testLabelStability() {
        let groundTruth = Array(repeating: "SPK1", count: 5)
        let predicted = ["A", "B", "A", "B", "A"]

        let metrics = DiarizationMetrics.compute(
            groundTruth: groundTruth,
            predicted: predicted
        )

        XCTAssertEqual(metrics.chunkAccuracy, 0.6)
        XCTAssertEqual(metrics.labelFlips, 4)
    }

    func testNilPredictions() {
        let groundTruth = ["A", "A", "B"]
        let predicted: [String?] = [nil, "X", "Y"]

        let metrics = DiarizationMetrics.compute(
            groundTruth: groundTruth,
            predicted: predicted.map { $0 ?? "__nil__" }
        )

        XCTAssertLessThan(metrics.chunkAccuracy, 1.0)
    }

    func testSpeakerCountDetection() {
        let groundTruth = ["A", "B", "C"]
        let predicted = ["X", "Y", "X"]

        let metrics = DiarizationMetrics.compute(
            groundTruth: groundTruth,
            predicted: predicted
        )

        XCTAssertEqual(metrics.speakerCountCorrect, false)
        XCTAssertEqual(metrics.detectedSpeakerCount, 2)
        XCTAssertEqual(metrics.actualSpeakerCount, 3)
    }
}
