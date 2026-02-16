import XCTest
@testable import QuickTranscriberLib

final class HungarianAlgorithmTests: XCTestCase {

    func testTwoByTwoPerfectMatch() {
        let cost: [[Int]] = [
            [0, 10],
            [10, 0],
        ]
        let assignment = HungarianAlgorithm.solve(cost)
        XCTAssertEqual(assignment, [0, 1])
    }

    func testTwoByTwoSwapped() {
        let cost: [[Int]] = [
            [10, 1],
            [1, 10],
        ]
        let assignment = HungarianAlgorithm.solve(cost)
        XCTAssertEqual(assignment, [1, 0])
    }

    func testThreeByThree() {
        let cost: [[Int]] = [
            [1, 2, 3],
            [2, 4, 6],
            [3, 6, 9],
        ]
        let assignment = HungarianAlgorithm.solve(cost)
        let totalCost = assignment.enumerated().map { cost[$0.offset][$0.element] }.reduce(0, +)
        XCTAssertEqual(totalCost, 10)
    }

    func testSingleElement() {
        let cost: [[Int]] = [[5]]
        let assignment = HungarianAlgorithm.solve(cost)
        XCTAssertEqual(assignment, [0])
    }

    func testEmpty() {
        let cost: [[Int]] = []
        let assignment = HungarianAlgorithm.solve(cost)
        XCTAssertEqual(assignment, [])
    }
}
