import XCTest
@testable import QuickTranscriberLib

final class ConfusionMatrixBuilderTests: XCTestCase {
    func test_build_countsAndFalseTarget() {
        // rows: (groundTruth, predicted)
        let rows: [(gt: String, pred: String)] = [
            ("上東", "上東"),
            ("上東", "神野"),   // false-神野 from 上東
            ("上東", "神野"),   // false-神野 from 上東
            ("森",   "神野"),   // false-神野 from 森
            ("森",   "森"),
            ("松浦", "松浦"),
        ]
        let result = ConfusionMatrixBuilder.build(
            rows: rows,
            speakers: ["松浦", "上東", "森", "神野"],
            falseTarget: "神野",
            silentSpeakers: ["神野"]
        )

        XCTAssertEqual(result.count(gt: "上東", pred: "神野"), 2)
        XCTAssertEqual(result.count(gt: "上東", pred: "上東"), 1)
        XCTAssertEqual(result.count(gt: "森", pred: "神野"), 1)
        // Total false-神野 = predicted 神野 while 神野 is silent (never a true GT)
        XCTAssertEqual(result.totalFalseTarget, 3)
        // Attribution: which GT speakers were mislabeled as 神野
        XCTAssertEqual(result.falseTargetByGroundTruth["上東"], 2)
        XCTAssertEqual(result.falseTargetByGroundTruth["森"], 1)
        // Per-GT accuracy (diagonal / row total)
        XCTAssertEqual(result.rowTotal(gt: "上東"), 3)
        XCTAssertEqual(result.accuracy(gt: "松浦"), 1.0, accuracy: 0.001)
    }
}
