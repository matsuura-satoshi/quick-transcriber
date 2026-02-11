import XCTest
@testable import MyTranscriberLib

final class LanguageTests: XCTestCase {
    func testLanguageProperties() {
        XCTAssertEqual(Language.english.rawValue, "en")
        XCTAssertEqual(Language.japanese.rawValue, "ja")
        XCTAssertEqual(Language.english.displayName, "English")
        XCTAssertEqual(Language.japanese.displayName, "Japanese")
        XCTAssertEqual(Language.allCases.count, 2)
    }
}
