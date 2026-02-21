import XCTest
@testable import QuickTranscriberLib

final class SegmentCharacterMapTests: XCTestCase {

    private let defaultNames = ["A": "A", "B": "B"]

    // MARK: - buildAttributedStringFromSegments returns map

    func testBuildReturnsMapWithCorrectEntryCount() {
        let segments = [
            ConfirmedSegment(text: "Hello", speaker: "A", speakerConfidence: 0.8),
            ConfirmedSegment(text: "World", speaker: "B", speakerConfidence: 0.7),
        ]
        let (_, map) = TranscriptionTextView.buildAttributedStringFromSegments(
            segments, language: "en", silenceThreshold: 1.0,
            fontSize: 15, unconfirmed: "", speakerDisplayNames: defaultNames
        )
        XCTAssertEqual(map.entries.count, 2)
    }

    func testBuildReturnsMapWithLabelRanges() {
        let segments = [
            ConfirmedSegment(text: "Hello", speaker: "A", speakerConfidence: 0.8),
        ]
        let (result, map) = TranscriptionTextView.buildAttributedStringFromSegments(
            segments, language: "en", silenceThreshold: 1.0,
            fontSize: 15, unconfirmed: "", speakerDisplayNames: defaultNames
        )
        // "A: Hello"
        XCTAssertEqual(result.string, "A: Hello")
        XCTAssertEqual(map.entries.count, 1)
        XCTAssertEqual(map.entries[0].labelRange, NSRange(location: 0, length: 3)) // "A: "
        XCTAssertEqual(map.entries[0].characterRange, NSRange(location: 3, length: 5)) // "Hello"
    }

    func testBuildReturnsMapNoSpeaker() {
        let segments = [
            ConfirmedSegment(text: "Hello"),
            ConfirmedSegment(text: "World"),
        ]
        let (_, map) = TranscriptionTextView.buildAttributedStringFromSegments(
            segments, language: "en", silenceThreshold: 1.0,
            fontSize: 15, unconfirmed: ""
        )
        XCTAssertEqual(map.entries.count, 2)
        XCTAssertNil(map.entries[0].labelRange)
        XCTAssertNil(map.entries[1].labelRange)
    }

    func testBuildReturnsMapSpeakerChangeWithNewline() {
        let segments = [
            ConfirmedSegment(text: "Hello", speaker: "A", speakerConfidence: 0.8),
            ConfirmedSegment(text: "World", speaker: "B", speakerConfidence: 0.7),
        ]
        let (result, map) = TranscriptionTextView.buildAttributedStringFromSegments(
            segments, language: "en", silenceThreshold: 1.0,
            fontSize: 15, unconfirmed: "", speakerDisplayNames: defaultNames
        )
        // "A: Hello\nB: World"
        XCTAssertEqual(result.string, "A: Hello\nB: World")
        // Second entry: label "B: " starts at 9
        XCTAssertEqual(map.entries[1].labelRange, NSRange(location: 9, length: 3))
        XCTAssertEqual(map.entries[1].characterRange, NSRange(location: 12, length: 5))
    }

    // MARK: - segmentIndices(overlapping:)

    func testSegmentIndicesOverlappingSingleSegment() {
        let segments = [
            ConfirmedSegment(text: "Hello", speaker: "A", speakerConfidence: 0.8),
            ConfirmedSegment(text: "World", speaker: "B", speakerConfidence: 0.7),
        ]
        let (_, map) = TranscriptionTextView.buildAttributedStringFromSegments(
            segments, language: "en", silenceThreshold: 1.0,
            fontSize: 15, unconfirmed: "", speakerDisplayNames: defaultNames
        )
        // Select "Hello" part (range 3..<8)
        let indices = map.segmentIndices(overlapping: NSRange(location: 3, length: 5))
        XCTAssertEqual(indices, [0])
    }

    func testSegmentIndicesOverlappingMultipleSegments() {
        let segments = [
            ConfirmedSegment(text: "Hello", speaker: "A", speakerConfidence: 0.8),
            ConfirmedSegment(text: "World", speaker: "B", speakerConfidence: 0.7),
        ]
        let (_, map) = TranscriptionTextView.buildAttributedStringFromSegments(
            segments, language: "en", silenceThreshold: 1.0,
            fontSize: 15, unconfirmed: "", speakerDisplayNames: defaultNames
        )
        // Select range spanning both segments
        let indices = map.segmentIndices(overlapping: NSRange(location: 3, length: 15))
        XCTAssertEqual(indices, [0, 1])
    }

    // MARK: - consecutiveBlockIndices(from:)

    func testConsecutiveBlockSingleSpeaker() {
        let segments = [
            ConfirmedSegment(text: "Hello", speaker: "A", speakerConfidence: 0.8),
            ConfirmedSegment(text: "world", speaker: "A", speakerConfidence: 0.8),
            ConfirmedSegment(text: "foo", speaker: "B", speakerConfidence: 0.7),
        ]
        let (_, map) = TranscriptionTextView.buildAttributedStringFromSegments(
            segments, language: "en", silenceThreshold: 1.0,
            fontSize: 15, unconfirmed: "", speakerDisplayNames: defaultNames
        )
        let block = map.consecutiveBlockIndices(from: 0, segments: segments)
        XCTAssertEqual(block, [0, 1])
    }

    func testConsecutiveBlockFromMiddle() {
        let segments = [
            ConfirmedSegment(text: "Hello", speaker: "A", speakerConfidence: 0.8),
            ConfirmedSegment(text: "world", speaker: "B", speakerConfidence: 0.7),
            ConfirmedSegment(text: "foo", speaker: "B", speakerConfidence: 0.7),
            ConfirmedSegment(text: "bar", speaker: "A", speakerConfidence: 0.8),
        ]
        let (_, map) = TranscriptionTextView.buildAttributedStringFromSegments(
            segments, language: "en", silenceThreshold: 1.0,
            fontSize: 15, unconfirmed: "", speakerDisplayNames: defaultNames
        )
        let block = map.consecutiveBlockIndices(from: 1, segments: segments)
        XCTAssertEqual(block, [1, 2])
    }

    // MARK: - labelEntry(at:)

    func testLabelEntryAtLabelPosition() {
        let segments = [
            ConfirmedSegment(text: "Hello", speaker: "A", speakerConfidence: 0.8),
        ]
        let (_, map) = TranscriptionTextView.buildAttributedStringFromSegments(
            segments, language: "en", silenceThreshold: 1.0,
            fontSize: 15, unconfirmed: "", speakerDisplayNames: defaultNames
        )
        // Position 0 is within "A: " label
        let entry = map.labelEntry(at: 0)
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.segmentIndex, 0)
    }

    func testLabelEntryAtTextPosition() {
        let segments = [
            ConfirmedSegment(text: "Hello", speaker: "A", speakerConfidence: 0.8),
        ]
        let (_, map) = TranscriptionTextView.buildAttributedStringFromSegments(
            segments, language: "en", silenceThreshold: 1.0,
            fontSize: 15, unconfirmed: "", speakerDisplayNames: defaultNames
        )
        // Position 3 is within "Hello" text, not label
        let entry = map.labelEntry(at: 3)
        XCTAssertNil(entry)
    }

    func testLabelEntryNoSpeaker() {
        let segments = [ConfirmedSegment(text: "Hello")]
        let (_, map) = TranscriptionTextView.buildAttributedStringFromSegments(
            segments, language: "en", silenceThreshold: 1.0,
            fontSize: 15, unconfirmed: ""
        )
        let entry = map.labelEntry(at: 0)
        XCTAssertNil(entry)
    }

    // MARK: - Display name in map

    func testBuildWithDisplayNameUsesDisplayNameInLabel() {
        let segments = [
            ConfirmedSegment(text: "Hello", speaker: "A", speakerConfidence: 0.8),
        ]
        let (result, map) = TranscriptionTextView.buildAttributedStringFromSegments(
            segments, language: "en", silenceThreshold: 1.0,
            fontSize: 15, unconfirmed: "",
            speakerDisplayNames: ["A": "Alice"]
        )
        // "Alice: Hello"
        XCTAssertEqual(result.string, "Alice: Hello")
        XCTAssertEqual(map.entries[0].labelRange, NSRange(location: 0, length: 7)) // "Alice: "
        XCTAssertEqual(map.entries[0].characterRange, NSRange(location: 7, length: 5)) // "Hello"
    }

    func testBuildWithoutDisplayNameFallsBackToUnknown() {
        let segments = [
            ConfirmedSegment(text: "Hello", speaker: "A", speakerConfidence: 0.8),
        ]
        let (result, _) = TranscriptionTextView.buildAttributedStringFromSegments(
            segments, language: "en", silenceThreshold: 1.0,
            fontSize: 15, unconfirmed: ""
        )
        // No display name mapping → falls back to "Unknown"
        XCTAssertEqual(result.string, "Unknown: Hello")
    }
}
