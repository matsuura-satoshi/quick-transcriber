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

    func test_zoomToAudioRelative_subtractsQtStart() throws {
        let zoom = """
        [松浦 知史 / Science Tokyo CERT / MATSUURA Satoshi] 09:45:05
        おはようございます。

        [Y.Uehigashi] 09:45:14
        始めます。
        """
        // qt start 09:44:23 -> 09:45:05 is +42s, 09:45:14 is +51s
        let segs = try SessionTimeAligner.zoomSegmentsAudioRelative(
            zoomRaw: zoom,
            qtStartSecondsOfDay: 9 * 3600 + 44 * 60 + 23,
            audioDurationSeconds: 695
        )
        XCTAssertEqual(segs.count, 2)
        XCTAssertEqual(segs[0].startSeconds, 42, accuracy: 0.001)
        XCTAssertEqual(segs[0].endSeconds, 51, accuracy: 0.001)   // next seg start
        XCTAssertEqual(segs[1].startSeconds, 51, accuracy: 0.001)
        XCTAssertEqual(segs[1].endSeconds, 695, accuracy: 0.001)  // audio duration
        XCTAssertEqual(segs[0].speaker, "松浦 知史 / Science Tokyo CERT / MATSUURA Satoshi")
    }
}
