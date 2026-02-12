import XCTest
@testable import QuickTranscriberLib

final class LanguageTests: XCTestCase {

    func testEnglish_rawValue() {
        XCTAssertEqual(Language.english.rawValue, "en")
    }

    func testJapanese_rawValue() {
        XCTAssertEqual(Language.japanese.rawValue, "ja")
    }

    func testEnglish_displayName() {
        XCTAssertEqual(Language.english.displayName, "English")
    }

    func testJapanese_displayName() {
        XCTAssertEqual(Language.japanese.displayName, "Japanese")
    }

    func testAllCases_count() {
        XCTAssertEqual(Language.allCases.count, 2)
    }

    func testIdentifiable_id() {
        XCTAssertEqual(Language.english.id, "en")
        XCTAssertEqual(Language.japanese.id, "ja")
    }
}
