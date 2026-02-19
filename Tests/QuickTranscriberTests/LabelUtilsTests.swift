import XCTest
@testable import QuickTranscriberLib

final class LabelUtilsTests: XCTestCase {

    func testNextAvailableLabelEmpty() {
        let label = LabelUtils.nextAvailableLabel(usedLabels: [])
        XCTAssertEqual(label, "A")
    }

    func testNextAvailableLabelSkipsUsed() {
        let label = LabelUtils.nextAvailableLabel(usedLabels: ["A", "B"])
        XCTAssertEqual(label, "C")
    }

    func testNextAvailableLabelSkipsGaps() {
        let label = LabelUtils.nextAvailableLabel(usedLabels: ["A", "C"])
        XCTAssertEqual(label, "B")
    }

    func testNextAvailableLabelWrapsToDoubleLetters() {
        var usedLabels = Set<String>()
        for i in 0..<26 {
            usedLabels.insert(String(UnicodeScalar(UInt8(65 + i))))
        }
        let label = LabelUtils.nextAvailableLabel(usedLabels: usedLabels)
        XCTAssertEqual(label, "AA")
    }

    func testNextAvailableLabelFallback() {
        var usedLabels = Set<String>()
        // Fill A-Z
        for i in 0..<26 {
            usedLabels.insert(String(UnicodeScalar(UInt8(65 + i))))
        }
        // Fill AA-AZ
        for j in 0..<26 {
            usedLabels.insert("A" + String(UnicodeScalar(UInt8(65 + j))))
        }
        let label = LabelUtils.nextAvailableLabel(usedLabels: usedLabels)
        XCTAssertEqual(label, "BA")
    }
}
