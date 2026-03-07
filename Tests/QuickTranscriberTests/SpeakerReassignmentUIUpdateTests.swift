import XCTest
@testable import QuickTranscriberLib

/// Tests for the bug: range-selection speaker reassignment with the same display name
/// produces no visible change because updateNSView only compares plain text (confirmedText),
/// missing speaker metadata changes that affect attributed string styling (confidence coloring).
final class SpeakerReassignmentUIUpdateTests: XCTestCase {

    // MARK: - Precondition: same display name produces identical confirmedText

    func testSameDisplayNameReassignmentProducesIdenticalText() {
        let trackerUUID = "tracker-123"
        let activeUUID = "active-456"
        let neighborUUID = "neighbor-789"
        let names = [trackerUUID: "Alice", activeUUID: "Alice", neighborUUID: "Bob"]

        let segmentsBefore = [
            ConfirmedSegment(text: "Hello", speaker: neighborUUID, speakerConfidence: 0.9),
            ConfirmedSegment(text: "World", speaker: trackerUUID, speakerConfidence: 0.3),
        ]
        let segmentsAfter = [
            ConfirmedSegment(text: "Hello", speaker: neighborUUID, speakerConfidence: 0.9),
            ConfirmedSegment(text: "World", speaker: activeUUID, speakerConfidence: 1.0),
        ]

        let textBefore = TranscriptionUtils.joinSegments(segmentsBefore, language: "en", speakerDisplayNames: names)
        let textAfter = TranscriptionUtils.joinSegments(segmentsAfter, language: "en", speakerDisplayNames: names)

        XCTAssertEqual(textBefore, textAfter,
            "Same display name must produce identical plain text — this is the precondition for the bug")
    }

    // MARK: - speakerFingerprint detects metadata changes

    func testSpeakerFingerprintDetectsUUIDChange() {
        let segments1 = [
            ConfirmedSegment(text: "Hello", speaker: "tracker-123", speakerConfidence: 0.3),
        ]
        let segments2 = [
            ConfirmedSegment(text: "Hello", speaker: "active-456", speakerConfidence: 0.3),
        ]

        let fp1 = TranscriptionTextView.speakerFingerprint(segments1)
        let fp2 = TranscriptionTextView.speakerFingerprint(segments2)

        XCTAssertNotEqual(fp1, fp2,
            "Different speaker UUIDs should produce different fingerprints")
    }

    func testSpeakerFingerprintDetectsConfidenceChange() {
        let segments1 = [
            ConfirmedSegment(text: "Hello", speaker: "A", speakerConfidence: 0.3),
        ]
        let segments2 = [
            ConfirmedSegment(text: "Hello", speaker: "A", speakerConfidence: 1.0),
        ]

        let fp1 = TranscriptionTextView.speakerFingerprint(segments1)
        let fp2 = TranscriptionTextView.speakerFingerprint(segments2)

        XCTAssertNotEqual(fp1, fp2,
            "Different confidence values should produce different fingerprints")
    }

    func testSpeakerFingerprintStableForIdenticalMetadata() {
        let segments = [
            ConfirmedSegment(text: "Hello", speaker: "A", speakerConfidence: 0.8),
            ConfirmedSegment(text: "World", speaker: "B", speakerConfidence: 0.5),
        ]

        let fp1 = TranscriptionTextView.speakerFingerprint(segments)
        let fp2 = TranscriptionTextView.speakerFingerprint(segments)

        XCTAssertEqual(fp1, fp2, "Same metadata should produce same fingerprint")
    }

    func testSpeakerFingerprintIgnoresTextChanges() {
        let segments1 = [
            ConfirmedSegment(text: "Hello", speaker: "A", speakerConfidence: 0.8),
        ]
        let segments2 = [
            ConfirmedSegment(text: "Completely different", speaker: "A", speakerConfidence: 0.8),
        ]

        let fp1 = TranscriptionTextView.speakerFingerprint(segments1)
        let fp2 = TranscriptionTextView.speakerFingerprint(segments2)

        XCTAssertEqual(fp1, fp2,
            "Fingerprint should only depend on speaker metadata, not text content")
    }

    // MARK: - Coordinator tracks speaker fingerprint

    func testCoordinatorUpdatesSpeakerFingerprint() {
        let coordinator = TranscriptionTextView.Coordinator()
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        coordinator.textView = textView

        let names = ["A": "Alice", "B": "Bob"]
        let segments = [
            ConfirmedSegment(text: "Hello", speaker: "A", speakerConfidence: 0.3),
            ConfirmedSegment(text: "World", speaker: "B", speakerConfidence: 0.9),
        ]

        coordinator.applySegmentUpdate(
            segments: segments, language: "en", silenceThreshold: 1.0,
            fontSize: 15, unconfirmed: "", oldFontSize: 15, oldUnconfirmed: "",
            speakerDisplayNames: names
        )

        let expected = TranscriptionTextView.speakerFingerprint(segments)
        XCTAssertEqual(coordinator.lastSpeakerFingerprint, expected,
            "Coordinator should track speaker fingerprint after applySegmentUpdate")
    }

    // MARK: - End-to-end: same display name reassignment detected by fingerprint

    func testSameDisplayNameReassignmentDetectedByFingerprint() {
        let trackerUUID = "tracker-123"
        let activeUUID = "active-456"
        let neighborUUID = "neighbor-789"
        let names = [trackerUUID: "Alice", activeUUID: "Alice", neighborUUID: "Bob"]

        let segmentsBefore = [
            ConfirmedSegment(text: "Hello", speaker: neighborUUID, speakerConfidence: 0.9),
            ConfirmedSegment(text: "World", speaker: trackerUUID, speakerConfidence: 0.3),
        ]
        let segmentsAfter = [
            ConfirmedSegment(text: "Hello", speaker: neighborUUID, speakerConfidence: 0.9),
            ConfirmedSegment(text: "World", speaker: activeUUID, speakerConfidence: 1.0),
        ]

        // Precondition: plain text is identical
        let textBefore = TranscriptionUtils.joinSegments(segmentsBefore, language: "en", speakerDisplayNames: names)
        let textAfter = TranscriptionUtils.joinSegments(segmentsAfter, language: "en", speakerDisplayNames: names)
        XCTAssertEqual(textBefore, textAfter, "Precondition: plain text must be identical")

        // Fingerprint must detect the metadata change
        let fpBefore = TranscriptionTextView.speakerFingerprint(segmentsBefore)
        let fpAfter = TranscriptionTextView.speakerFingerprint(segmentsAfter)
        XCTAssertNotEqual(fpBefore, fpAfter,
            "Fingerprint must detect change even when display text is identical")
    }

    // MARK: - Confidence coloring is applied after same-name reassignment

    func testConfidenceColorUpdatesAfterSameNameReassignment() {
        let coordinator = TranscriptionTextView.Coordinator()
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        coordinator.textView = textView

        let trackerUUID = "tracker-123"
        let activeUUID = "active-456"
        let neighborUUID = "neighbor-789"
        let names = [trackerUUID: "Alice", activeUUID: "Alice", neighborUUID: "Bob"]

        // Initial: tracker UUID with low confidence
        let segments1 = [
            ConfirmedSegment(text: "Hello", speaker: neighborUUID, speakerConfidence: 0.9),
            ConfirmedSegment(text: "World", speaker: trackerUUID, speakerConfidence: 0.3),
        ]
        coordinator.applySegmentUpdate(
            segments: segments1, language: "en", silenceThreshold: 1.0,
            fontSize: 15, unconfirmed: "", oldFontSize: 15, oldUnconfirmed: "",
            speakerDisplayNames: names
        )

        // Verify low confidence coloring on "Alice: " label
        let text = textView.textStorage!.string
        // Text: "Bob: Hello\nAlice: World"
        let aliceStart = (text as NSString).range(of: "Alice: ")
        XCTAssertTrue(aliceStart.location != NSNotFound, "Alice label should exist")
        var effRange1 = NSRange()
        let color1 = textView.textStorage!.attributes(at: aliceStart.location, effectiveRange: &effRange1)[.foregroundColor] as? NSColor
        XCTAssertEqual(color1, NSColor.secondaryLabelColor, "Low confidence should show secondary color")

        // Reassigned: active UUID with high confidence, same display name "Alice"
        let segments2 = [
            ConfirmedSegment(text: "Hello", speaker: neighborUUID, speakerConfidence: 0.9),
            ConfirmedSegment(text: "World", speaker: activeUUID, speakerConfidence: 1.0),
        ]
        coordinator.applySegmentUpdate(
            segments: segments2, language: "en", silenceThreshold: 1.0,
            fontSize: 15, unconfirmed: "", oldFontSize: 15, oldUnconfirmed: "",
            speakerDisplayNames: names
        )

        // Verify high confidence coloring applied
        let updatedText = textView.textStorage!.string
        let updatedAliceStart = (updatedText as NSString).range(of: "Alice: ")
        var effRange2 = NSRange()
        let color2 = textView.textStorage!.attributes(at: updatedAliceStart.location, effectiveRange: &effRange2)[.foregroundColor] as? NSColor
        XCTAssertEqual(color2, NSColor.labelColor,
            "After reassignment, high confidence should show labelColor")
    }
}
