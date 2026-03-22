import XCTest
@testable import QuickTranscriberLib

/// Tests verifying segmentMap is set correctly for segments without speaker data.
/// Bug: when no segment has speakerConfidence, updateNSView skipped applySegmentUpdate,
/// leaving segmentMap nil and making right-click speaker assignment impossible.
final class SegmentMapNoSpeakerTests: XCTestCase {

    // MARK: - applySegmentUpdate sets segmentMap on InteractiveTranscriptionTextView

    func testApplySegmentUpdateSetsSegmentMapForNoSpeakerSegments() {
        let coordinator = TranscriptionTextView.Coordinator()
        let textView = InteractiveTranscriptionTextView()
        coordinator.textView = textView

        let segments = [
            ConfirmedSegment(text: "Hello"),
            ConfirmedSegment(text: "World"),
        ]

        coordinator.applySegmentUpdate(
            segments: segments, language: "en", silenceThreshold: 1.0,
            fontSize: 15, unconfirmed: "", oldFontSize: 0, oldUnconfirmed: ""
        )

        XCTAssertNotNil(textView.segmentMap, "segmentMap should be set even when no speaker data")
        XCTAssertEqual(textView.segmentMap?.entries.count, 2)
    }

    func testSegmentMapEntriesHaveNilLabelRangeForNoSpeakerSegments() {
        let coordinator = TranscriptionTextView.Coordinator()
        let textView = InteractiveTranscriptionTextView()
        coordinator.textView = textView

        let segments = [
            ConfirmedSegment(text: "Hello"),
            ConfirmedSegment(text: "World"),
        ]

        coordinator.applySegmentUpdate(
            segments: segments, language: "en", silenceThreshold: 1.0,
            fontSize: 15, unconfirmed: "", oldFontSize: 0, oldUnconfirmed: ""
        )

        let map = textView.segmentMap!
        XCTAssertNil(map.entries[0].labelRange, "No speaker → no label range")
        XCTAssertNil(map.entries[1].labelRange, "No speaker → no label range")
    }

    func testSegmentMapEntriesAreOverlappableForNoSpeakerSegments() {
        let coordinator = TranscriptionTextView.Coordinator()
        let textView = InteractiveTranscriptionTextView()
        coordinator.textView = textView

        let segments = [
            ConfirmedSegment(text: "Hello"),
            ConfirmedSegment(text: "World"),
        ]

        coordinator.applySegmentUpdate(
            segments: segments, language: "en", silenceThreshold: 1.0,
            fontSize: 15, unconfirmed: "", oldFontSize: 0, oldUnconfirmed: ""
        )

        let map = textView.segmentMap!
        // "Hello World" (with space) → select "Hello" part
        let indices = map.segmentIndices(overlapping: map.entries[0].characterRange)
        XCTAssertEqual(indices, [0], "Should find segment by overlapping range even without speaker")
    }

    // MARK: - Mixed: some segments with speaker, some without

    func testSegmentMapSetForMixedSpeakerSegments() {
        let coordinator = TranscriptionTextView.Coordinator()
        let textView = InteractiveTranscriptionTextView()
        coordinator.textView = textView

        let segments = [
            ConfirmedSegment(text: "Hello", speaker: "A", speakerConfidence: 0.8),
            ConfirmedSegment(text: "World"),
        ]

        coordinator.applySegmentUpdate(
            segments: segments, language: "en", silenceThreshold: 1.0,
            fontSize: 15, unconfirmed: "", oldFontSize: 0, oldUnconfirmed: "",
            speakerDisplayNames: ["A": "Alice"]
        )

        XCTAssertNotNil(textView.segmentMap)
        XCTAssertEqual(textView.segmentMap?.entries.count, 2)
        // First segment has label range (speaker assigned), second doesn't
        XCTAssertNotNil(textView.segmentMap?.entries[0].labelRange)
        XCTAssertNil(textView.segmentMap?.entries[1].labelRange)
    }

    // MARK: - availableSpeakers interaction

    func testAvailableSpeakersSetOnInteractiveTextView() {
        let textView = InteractiveTranscriptionTextView()
        let speakerId = UUID()
        textView.availableSpeakers = [SpeakerMenuItem(id: speakerId, displayName: "Alice")]

        XCTAssertEqual(textView.availableSpeakers.count, 1)
        XCTAssertEqual(textView.availableSpeakers[0].displayName, "Alice")
    }

    // MARK: - Regression: segmentMap must be set regardless of hasSpeakerConfidence

    func testHasSpeakerConfidenceConditionDoesNotBlockSegmentMap() {
        // This test verifies the fix: segments without speakerConfidence should still
        // get a segmentMap through applySegmentUpdate.
        let coordinator = TranscriptionTextView.Coordinator()
        let textView = InteractiveTranscriptionTextView()
        coordinator.textView = textView

        // Segments with NO speakerConfidence (the bug scenario)
        let segments = [
            ConfirmedSegment(text: "会議の議題について"),
            ConfirmedSegment(text: "承知しました"),
            ConfirmedSegment(text: "次の案件に移ります"),
        ]

        // hasSpeakerConfidence is false for these segments
        let hasSpeakerConfidence = segments.contains { $0.speakerConfidence != nil }
        XCTAssertFalse(hasSpeakerConfidence, "Precondition: no speaker confidence data")

        // applySegmentUpdate should still produce a valid segmentMap
        coordinator.applySegmentUpdate(
            segments: segments, language: "ja", silenceThreshold: 1.0,
            fontSize: 15, unconfirmed: "", oldFontSize: 0, oldUnconfirmed: ""
        )

        XCTAssertNotNil(textView.segmentMap, "segmentMap MUST be set even without speakerConfidence")
        XCTAssertEqual(textView.segmentMap?.entries.count, 3)

        // All segments should be addressable for right-click assignment
        for (i, entry) in textView.segmentMap!.entries.enumerated() {
            XCTAssertEqual(entry.segmentIndex, i)
            XCTAssertGreaterThan(entry.characterRange.length, 0,
                                 "Segment \(i) must have non-zero character range")
        }
    }
}
