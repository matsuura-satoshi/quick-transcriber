import XCTest
@testable import QuickTranscriberLib

final class ZoomTranscriptParserTests: XCTestCase {
    func test_parse_extractsSpeakerTimestampAndText() throws {
        let raw = """
        [松浦 知史 / Science Tokyo CERT / MATSUURA Satoshi] 09:45:05
        おはようございます。

        [今村＠情報セキュリティ室] 09:45:09
        おはようございます。

        [Y.Uehigashi] 09:45:11
        ありがとうございます。
        """

        let segments = try ZoomTranscriptParser.parse(
            raw,
            sessionStart: ZoomTranscriptParser.timeOfDay(hour: 9, minute: 45, second: 0),
            sessionDurationSeconds: 60
        )

        XCTAssertEqual(segments.count, 3)
        XCTAssertEqual(segments[0].speaker, "松浦 知史 / Science Tokyo CERT / MATSUURA Satoshi")
        XCTAssertEqual(segments[0].text, "おはようございます。")
        XCTAssertEqual(segments[0].startSeconds, 5.0, accuracy: 0.001)
        XCTAssertEqual(segments[0].endSeconds, 9.0, accuracy: 0.001)
        XCTAssertEqual(segments[1].speaker, "今村＠情報セキュリティ室")
        XCTAssertEqual(segments[1].endSeconds, 11.0, accuracy: 0.001)
        XCTAssertEqual(segments[2].speaker, "Y.Uehigashi")
        // Last segment ends at session duration
        XCTAssertEqual(segments[2].endSeconds, 60.0, accuracy: 0.001)
    }

    func test_parse_handlesMultilineText() throws {
        let raw = """
        [松浦] 09:45:00
        line one.
        line two.

        [上東] 09:45:10
        next.
        """

        let segments = try ZoomTranscriptParser.parse(
            raw,
            sessionStart: ZoomTranscriptParser.timeOfDay(hour: 9, minute: 45, second: 0),
            sessionDurationSeconds: 30
        )

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].text, "line one.\nline two.")
    }

    func test_parse_skipsEmptyLines() throws {
        let raw = """


        [松浦] 09:45:00
        hello.

        """

        let segments = try ZoomTranscriptParser.parse(
            raw,
            sessionStart: ZoomTranscriptParser.timeOfDay(hour: 9, minute: 45, second: 0),
            sessionDurationSeconds: 5
        )

        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].text, "hello.")
        XCTAssertEqual(segments[0].endSeconds, 5.0, accuracy: 0.001)
    }

    func test_parse_throwsOnMalformedTimestamp() {
        let raw = """
        [松浦] 09:45
        timestamp is missing seconds, malformed.
        """
        XCTAssertThrowsError(
            try ZoomTranscriptParser.parse(
                raw,
                sessionStart: 0,
                sessionDurationSeconds: 60
            )
        ) { error in
            guard case ZoomTranscriptParserError.malformedHeader = error else {
                XCTFail("expected malformedHeader, got \(error)")
                return
            }
        }
    }

    func test_parse_handlesRealZoomTranscript_2026_04_21() throws {
        let path = NSString(string: "~/Documents/QuickTranscriber/real-sessions/2026-04-21_CERTインシデント情報共有/zoom_transcript.txt")
            .expandingTildeInPath
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path), "real-session 2026-04-21 not present")
        let raw = try String(contentsOfFile: path, encoding: .utf8)
        let segments = try ZoomTranscriptParser.parse(
            raw,
            sessionStart: ZoomTranscriptParser.timeOfDay(hour: 9, minute: 45, second: 0),
            sessionDurationSeconds: 695.1
        )
        XCTAssertEqual(segments.count, 130)
        XCTAssertEqual(ZoomTranscriptParser.uniqueSpeakers(in: segments).count, 4)
        // Sanity: timestamps are monotonic and within session bounds.
        for i in 0..<segments.count {
            XCTAssertGreaterThanOrEqual(segments[i].startSeconds, 0)
            XCTAssertLessThanOrEqual(segments[i].endSeconds, 1000)
            XCTAssertLessThanOrEqual(segments[i].startSeconds, segments[i].endSeconds)
            if i + 1 < segments.count {
                XCTAssertLessThanOrEqual(segments[i].startSeconds, segments[i + 1].startSeconds)
            }
        }
    }

    func test_parse_handlesRealZoomTranscript_2026_04_23() throws {
        let path = NSString(string: "~/Documents/QuickTranscriber/real-sessions/2026-04-23_CERTインシデント情報共有/zoom_transcript.txt")
            .expandingTildeInPath
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path), "real-session 2026-04-23 not present")
        let raw = try String(contentsOfFile: path, encoding: .utf8)
        let segments = try ZoomTranscriptParser.parse(
            raw,
            sessionStart: ZoomTranscriptParser.timeOfDay(hour: 9, minute: 44, second: 0),
            sessionDurationSeconds: 904.1
        )
        XCTAssertEqual(segments.count, 189)
        XCTAssertEqual(ZoomTranscriptParser.uniqueSpeakers(in: segments).count, 5)
    }

    func test_uniqueSpeakers_returnsSortedDistinctNames() throws {
        let raw = """
        [松浦] 09:45:00
        a.

        [上東] 09:45:05
        b.

        [松浦] 09:45:10
        c.
        """
        let segments = try ZoomTranscriptParser.parse(
            raw,
            sessionStart: ZoomTranscriptParser.timeOfDay(hour: 9, minute: 45, second: 0),
            sessionDurationSeconds: 20
        )
        let speakers = ZoomTranscriptParser.uniqueSpeakers(in: segments)
        XCTAssertEqual(speakers, ["上東", "松浦"])
    }
}
