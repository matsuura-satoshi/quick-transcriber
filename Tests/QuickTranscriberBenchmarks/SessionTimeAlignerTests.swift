import XCTest
@testable import QuickTranscriberLib

final class SessionTimeAlignerTests: XCTestCase {
    func test_secondsOfDay_parsesISO8601Frontmatter() throws {
        let md = """
        ---
        date: 2026-04-21T09:44:23+09:00
        language: Japanese
        ---

        神野: はい
        """
        let sod = try SessionTimeAligner.qtStartSecondsOfDay(fromFrontmatter: md)
        XCTAssertEqual(sod, 9 * 3600 + 44 * 60 + 23, accuracy: 0.001)
    }

    func test_secondsOfDay_throwsWhenDateMissing() {
        XCTAssertThrowsError(
            try SessionTimeAligner.qtStartSecondsOfDay(fromFrontmatter: "---\nlanguage: Japanese\n---\n")
        )
    }
}
