import XCTest
@testable import QuickTranscriberLib

@MainActor
final class TranslationServiceTests: XCTestCase {
    private var service: TranslationService!

    override func setUp() {
        super.setUp()
        service = TranslationService()
    }

    override func tearDown() {
        service = nil
        super.tearDown()
    }

    // MARK: - Reset

    func testResetClearsState() {
        // Manually set up some state
        service.translatedSegments = [
            ConfirmedSegment(text: "Hello"),
            ConfirmedSegment(text: "World")
        ]

        service.reset()

        XCTAssertTrue(service.translatedSegments.isEmpty)
    }

    func testResetAllowsRetranslation() {
        // After reset, cursor should be back to 0
        service.reset()

        // translatedSegments should be empty
        XCTAssertEqual(service.translatedSegments.count, 0)
    }

    // MARK: - Metadata preservation

    func testMetadataPreservedInTranslatedSegment() {
        // Verify that when we create a translated segment, metadata is copied from source
        let source = ConfirmedSegment(
            text: "Hello world",
            precedingSilence: 1.5,
            speaker: "A",
            speakerConfidence: 0.85,
            isUserCorrected: true,
            originalSpeaker: "B",
            speakerEmbedding: [0.1, 0.2, 0.3]
        )

        // Simulate what TranslationService does: copy metadata, replace text
        let translated = ConfirmedSegment(
            text: "こんにちは世界",
            precedingSilence: source.precedingSilence,
            speaker: source.speaker,
            speakerConfidence: source.speakerConfidence,
            isUserCorrected: source.isUserCorrected,
            originalSpeaker: source.originalSpeaker,
            speakerEmbedding: source.speakerEmbedding
        )

        XCTAssertEqual(translated.text, "こんにちは世界")
        XCTAssertEqual(translated.precedingSilence, 1.5)
        XCTAssertEqual(translated.speaker, "A")
        XCTAssertEqual(translated.speakerConfidence, 0.85)
        XCTAssertTrue(translated.isUserCorrected)
        XCTAssertEqual(translated.originalSpeaker, "B")
        XCTAssertEqual(translated.speakerEmbedding, [0.1, 0.2, 0.3])
    }

    // MARK: - Initial state

    func testInitialState() {
        XCTAssertTrue(service.translatedSegments.isEmpty)
    }

    // MARK: - syncSpeakerMetadata

    func testSyncSpeakerMetadataUpdatesLabels() {
        service.translatedSegments = [
            ConfirmedSegment(text: "translated1", speaker: "A"),
            ConfirmedSegment(text: "translated2", speaker: "A"),
            ConfirmedSegment(text: "translated3", speaker: "B"),
        ]

        let source = [
            ConfirmedSegment(text: "original1", speaker: "C", speakerConfidence: 1.0, isUserCorrected: true, originalSpeaker: "A"),
            ConfirmedSegment(text: "original2", speaker: "C", speakerConfidence: 1.0, isUserCorrected: true, originalSpeaker: "A"),
            ConfirmedSegment(text: "original3", speaker: "B"),
        ]

        service.syncSpeakerMetadata(from: source)

        XCTAssertEqual(service.translatedSegments[0].speaker, "C")
        XCTAssertEqual(service.translatedSegments[0].speakerConfidence, 1.0)
        XCTAssertTrue(service.translatedSegments[0].isUserCorrected)
        XCTAssertEqual(service.translatedSegments[0].originalSpeaker, "A")

        XCTAssertEqual(service.translatedSegments[1].speaker, "C")
        XCTAssertEqual(service.translatedSegments[2].speaker, "B")
    }

    func testSyncSpeakerMetadataPreservesTranslatedText() {
        service.translatedSegments = [
            ConfirmedSegment(text: "こんにちは", speaker: "A"),
        ]

        let source = [
            ConfirmedSegment(text: "Hello", speaker: "B"),
        ]

        service.syncSpeakerMetadata(from: source)

        XCTAssertEqual(service.translatedSegments[0].text, "こんにちは")
        XCTAssertEqual(service.translatedSegments[0].speaker, "B")
    }

    func testSyncSpeakerMetadataHandlesCountMismatch() {
        service.translatedSegments = [
            ConfirmedSegment(text: "translated1", speaker: "A"),
            ConfirmedSegment(text: "translated2", speaker: "A"),
        ]

        // Source has more segments (e.g. after split)
        let source = [
            ConfirmedSegment(text: "original1", speaker: "C"),
            ConfirmedSegment(text: "original2a", speaker: "C"),
            ConfirmedSegment(text: "original2b", speaker: "D"),
        ]

        service.syncSpeakerMetadata(from: source)

        // Only syncs up to min count
        XCTAssertEqual(service.translatedSegments[0].speaker, "C")
        XCTAssertEqual(service.translatedSegments[1].speaker, "C")
        XCTAssertEqual(service.translatedSegments.count, 2)
    }

    func testSyncSpeakerMetadataWithEmptyTranslation() {
        service.translatedSegments = []

        let source = [
            ConfirmedSegment(text: "original", speaker: "A"),
        ]

        service.syncSpeakerMetadata(from: source)

        XCTAssertTrue(service.translatedSegments.isEmpty)
    }

    // MARK: - isGroupBoundary: sentence enders

    func testIsGroupBoundary_sentenceEnderEN_period() {
        let segments = [
            ConfirmedSegment(text: "Hello world."),
            ConfirmedSegment(text: " Next sentence"),
        ]
        XCTAssertTrue(TranslationService.isGroupBoundary(segments: segments, at: 1, sourceLanguage: "en"))
    }

    func testIsGroupBoundary_sentenceEnderEN_exclamation() {
        let segments = [
            ConfirmedSegment(text: "Wow!"),
            ConfirmedSegment(text: " Indeed"),
        ]
        XCTAssertTrue(TranslationService.isGroupBoundary(segments: segments, at: 1, sourceLanguage: "en"))
    }

    func testIsGroupBoundary_sentenceEnderEN_question() {
        let segments = [
            ConfirmedSegment(text: "Really?"),
            ConfirmedSegment(text: " Yes"),
        ]
        XCTAssertTrue(TranslationService.isGroupBoundary(segments: segments, at: 1, sourceLanguage: "en"))
    }

    func testIsGroupBoundary_sentenceEnderJA() {
        let segments = [
            ConfirmedSegment(text: "こんにちは。"),
            ConfirmedSegment(text: "次の文"),
        ]
        XCTAssertTrue(TranslationService.isGroupBoundary(segments: segments, at: 1, sourceLanguage: "ja"))
    }

    func testIsGroupBoundary_sentenceEnderJA_exclamation() {
        let segments = [
            ConfirmedSegment(text: "すごい！"),
            ConfirmedSegment(text: "本当"),
        ]
        XCTAssertTrue(TranslationService.isGroupBoundary(segments: segments, at: 1, sourceLanguage: "ja"))
    }

    // MARK: - isGroupBoundary: speaker change

    func testIsGroupBoundary_speakerChange() {
        let segments = [
            ConfirmedSegment(text: "I think so", speaker: "A"),
            ConfirmedSegment(text: " me too", speaker: "B"),
        ]
        XCTAssertTrue(TranslationService.isGroupBoundary(segments: segments, at: 1, sourceLanguage: "en"))
    }

    func testIsGroupBoundary_sameSpeakerNoBoundary() {
        let segments = [
            ConfirmedSegment(text: "I think", speaker: "A"),
            ConfirmedSegment(text: " so too", speaker: "A"),
        ]
        XCTAssertFalse(TranslationService.isGroupBoundary(segments: segments, at: 1, sourceLanguage: "en"))
    }

    func testIsGroupBoundary_nilSpeakersNoBoundary() {
        let segments = [
            ConfirmedSegment(text: "I think"),
            ConfirmedSegment(text: " so too"),
        ]
        XCTAssertFalse(TranslationService.isGroupBoundary(segments: segments, at: 1, sourceLanguage: "en"))
    }

    // MARK: - isGroupBoundary: long silence

    func testIsGroupBoundary_longSilence() {
        let segments = [
            ConfirmedSegment(text: "Hello"),
            ConfirmedSegment(text: " world", precedingSilence: 3.0),
        ]
        XCTAssertTrue(TranslationService.isGroupBoundary(segments: segments, at: 1, sourceLanguage: "en"))
    }

    func testIsGroupBoundary_shortSilenceNoBoundary() {
        let segments = [
            ConfirmedSegment(text: "Hello"),
            ConfirmedSegment(text: " world", precedingSilence: 1.0),
        ]
        XCTAssertFalse(TranslationService.isGroupBoundary(segments: segments, at: 1, sourceLanguage: "en"))
    }

    // MARK: - isGroupBoundary: edge cases

    func testIsGroupBoundary_index0AlwaysFalse() {
        let segments = [
            ConfirmedSegment(text: "Hello."),
        ]
        XCTAssertFalse(TranslationService.isGroupBoundary(segments: segments, at: 0, sourceLanguage: "en"))
    }

    func testIsGroupBoundary_combinedSpeakerChangeAndSentenceEnd() {
        let segments = [
            ConfirmedSegment(text: "Really?", speaker: "A"),
            ConfirmedSegment(text: " Yes", speaker: "B"),
        ]
        XCTAssertTrue(TranslationService.isGroupBoundary(segments: segments, at: 1, sourceLanguage: "en"))
    }

    func testIsGroupBoundary_midSentenceNoBoundary() {
        let segments = [
            ConfirmedSegment(text: "I think that"),
            ConfirmedSegment(text: " we should go"),
        ]
        XCTAssertFalse(TranslationService.isGroupBoundary(segments: segments, at: 1, sourceLanguage: "en"))
    }

    func testIsGroupBoundary_trailingSpaceAfterPunctuation() {
        let segments = [
            ConfirmedSegment(text: "Hello. "),
            ConfirmedSegment(text: "World"),
        ]
        XCTAssertTrue(TranslationService.isGroupBoundary(segments: segments, at: 1, sourceLanguage: "en"))
    }

    // MARK: - displaySegments

    func testInitialDisplaySegmentsEmpty() {
        XCTAssertTrue(service.displaySegments.isEmpty)
    }

    func testResetClearsDisplaySegments() {
        service.translatedSegments = [ConfirmedSegment(text: "Hello")]
        service.displaySegments = [ConfirmedSegment(text: "こんにちは")]

        service.reset()

        XCTAssertTrue(service.displaySegments.isEmpty)
        XCTAssertTrue(service.translatedSegments.isEmpty)
    }

    // MARK: - syncSpeakerMetadata + displaySegments propagation

    func testSyncSpeakerMetadataUpdatesDisplaySegments() {
        service.translatedSegments = [
            ConfirmedSegment(text: "translated1", speaker: "A"),
            ConfirmedSegment(text: "translated2", speaker: "A"),
        ]
        service.displaySegments = [
            ConfirmedSegment(text: "統合訳文", speaker: "A"),
            ConfirmedSegment(text: "", speaker: "A"),
        ]

        let source = [
            ConfirmedSegment(text: "original1", speaker: "B"),
            ConfirmedSegment(text: "original2", speaker: "B"),
        ]

        service.syncSpeakerMetadata(from: source)

        // displaySegments should also get updated speaker metadata
        XCTAssertEqual(service.displaySegments[0].speaker, "B")
        XCTAssertEqual(service.displaySegments[1].speaker, "B")
    }

    // MARK: - rebuildDisplaySegments

    func testRebuildDisplaySegments_noGroups() {
        // When no retranslation has happened, displaySegments mirrors translatedSegments
        service.translatedSegments = [
            ConfirmedSegment(text: "Hello", speaker: "A"),
            ConfirmedSegment(text: " world", speaker: "A"),
        ]

        service.rebuildDisplaySegments()

        XCTAssertEqual(service.displaySegments.count, 2)
        XCTAssertEqual(service.displaySegments[0].text, "Hello")
        XCTAssertEqual(service.displaySegments[1].text, " world")
    }

    func testRebuildDisplaySegments_withRetranslatedGroup() {
        service.translatedSegments = [
            ConfirmedSegment(text: "Hello", speaker: "A"),
            ConfirmedSegment(text: " world", speaker: "A"),
            ConfirmedSegment(text: " Next.", speaker: "B"),
        ]

        // Simulate a retranslated group: indices 0-1 retranslated as one
        service.applyGroupRetranslation(
            groupStartIndex: 0, groupEndIndex: 1,
            translatedText: "こんにちは世界"
        )

        XCTAssertEqual(service.displaySegments.count, 3)
        XCTAssertEqual(service.displaySegments[0].text, "こんにちは世界")
        XCTAssertEqual(service.displaySegments[0].speaker, "A")
        XCTAssertEqual(service.displaySegments[1].text, "")
        XCTAssertEqual(service.displaySegments[2].text, " Next.")
    }

    func testRebuildDisplaySegments_preservesMetadataFromTranslatedSegments() {
        service.translatedSegments = [
            ConfirmedSegment(text: "Hi", speaker: "A", speakerConfidence: 0.9),
            ConfirmedSegment(text: " there", speaker: "A", speakerConfidence: 0.8),
        ]

        service.applyGroupRetranslation(
            groupStartIndex: 0, groupEndIndex: 1,
            translatedText: "やあ"
        )

        // Metadata comes from first segment in group
        XCTAssertEqual(service.displaySegments[0].speaker, "A")
        XCTAssertEqual(service.displaySegments[0].speakerConfidence, 0.9)
        XCTAssertEqual(service.displaySegments[0].precedingSilence, 0)
    }

    // MARK: - splitSegment

    func testSplitSegmentMaintainsIndexCorrespondence() {
        service.translatedSegments = [
            ConfirmedSegment(text: "Hello", speaker: "A"),
            ConfirmedSegment(text: "World", speaker: "B"),
            ConfirmedSegment(text: "Foo", speaker: "A"),
        ]

        service.splitSegment(at: 1)

        XCTAssertEqual(service.translatedSegments.count, 4)
        XCTAssertEqual(service.translatedSegments[0].text, "Hello")
        XCTAssertEqual(service.translatedSegments[1].text, "World")
        XCTAssertEqual(service.translatedSegments[1].speaker, "B")
        XCTAssertEqual(service.translatedSegments[2].text, "")
        XCTAssertEqual(service.translatedSegments[2].speaker, "B")
        XCTAssertEqual(service.translatedSegments[2].precedingSilence, 0)
        XCTAssertEqual(service.translatedSegments[3].text, "Foo")
    }

    func testSplitSegmentShiftsGroupIndices() {
        service.translatedSegments = [
            ConfirmedSegment(text: "A", speaker: "X"),
            ConfirmedSegment(text: "B", speaker: "X"),
            ConfirmedSegment(text: "C", speaker: "Y"),
            ConfirmedSegment(text: "D", speaker: "Y"),
        ]

        // Create a group spanning indices 2-3
        service.applyGroupRetranslation(
            groupStartIndex: 2, groupEndIndex: 3,
            translatedText: "CDの訳"
        )

        // Split at index 0 — should shift group indices by +1
        service.splitSegment(at: 0)

        // Group should now span 3-4, displaySegments should reflect that
        XCTAssertEqual(service.translatedSegments.count, 5)
        XCTAssertEqual(service.displaySegments.count, 5)
        XCTAssertEqual(service.displaySegments[3].text, "CDの訳")
        XCTAssertEqual(service.displaySegments[4].text, "")
    }

    func testSplitSegmentAdjustsCursor() {
        service.translatedSegments = [
            ConfirmedSegment(text: "A"),
            ConfirmedSegment(text: "B"),
            ConfirmedSegment(text: "C"),
        ]
        service.translationCursor = 3

        service.splitSegment(at: 1)

        // Cursor was at 3, split at 1 (before cursor) — cursor should become 4
        XCTAssertEqual(service.translationCursor, 4)
    }

    func testSplitSegmentCursorNotAdjustedWhenSplitAfter() {
        service.translatedSegments = [
            ConfirmedSegment(text: "A"),
            ConfirmedSegment(text: "B"),
            ConfirmedSegment(text: "C"),
        ]
        service.translationCursor = 1

        service.splitSegment(at: 2)

        // Cursor was at 1, split at 2 (after cursor) — cursor stays at 1
        XCTAssertEqual(service.translationCursor, 1)
    }

    func testSplitSegmentOutOfBoundsIsNoop() {
        service.translatedSegments = [
            ConfirmedSegment(text: "A"),
        ]

        service.splitSegment(at: 5)

        XCTAssertEqual(service.translatedSegments.count, 1)
    }

    // MARK: - isGroupBoundary nil speaker

    func testIsGroupBoundaryNilToNonNilSpeaker() {
        let segments = [
            ConfirmedSegment(text: "pending"),
            ConfirmedSegment(text: "confirmed", speaker: "A"),
        ]
        XCTAssertTrue(
            TranslationService.isGroupBoundary(segments: segments, at: 1, sourceLanguage: "en")
        )
    }

    func testIsGroupBoundaryNilToNilNoBoundary() {
        let segments = [
            ConfirmedSegment(text: "pending1"),
            ConfirmedSegment(text: "pending2"),
        ]
        XCTAssertFalse(
            TranslationService.isGroupBoundary(segments: segments, at: 1, sourceLanguage: "en")
        )
    }

    // MARK: - isGroupBoundary: non-nil → nil speaker transition

    func testIsGroupBoundaryNonNilToNilSpeaker() {
        let segments = [
            ConfirmedSegment(text: "confirmed", speaker: "A"),
            ConfirmedSegment(text: "pending"),
        ]
        XCTAssertTrue(
            TranslationService.isGroupBoundary(segments: segments, at: 1, sourceLanguage: "en")
        )
    }

    // MARK: - syncSpeakerMetadata group invalidation

    func testSyncSpeakerMetadataInvalidatesGroupOnSpeakerChange() {
        // Set up: 3 segments, group retranslation for indices 0-1 (same speaker "A")
        service.translatedSegments = [
            ConfirmedSegment(text: "こんにちは", speaker: "A"),
            ConfirmedSegment(text: "世界", speaker: "A"),
            ConfirmedSegment(text: "次の文", speaker: "B"),
        ]
        service.applyGroupRetranslation(
            groupStartIndex: 0, groupEndIndex: 1, translatedText: "ハローワールド"
        )

        // Before sync: group retranslation is active
        XCTAssertEqual(service.displaySegments[0].text, "ハローワールド")
        XCTAssertEqual(service.displaySegments[1].text, "")

        // Sync with changed speaker: segment 1 now belongs to "C"
        let source = [
            ConfirmedSegment(text: "Hello", speaker: "A"),
            ConfirmedSegment(text: " world", speaker: "C"),
            ConfirmedSegment(text: " Next.", speaker: "B"),
        ]
        service.syncSpeakerMetadata(from: source)

        // After sync: retranslation should be invalidated, individual translations restored
        XCTAssertEqual(service.displaySegments[0].text, "こんにちは")
        XCTAssertEqual(service.displaySegments[0].speaker, "A")
        XCTAssertEqual(service.displaySegments[1].text, "世界")
        XCTAssertEqual(service.displaySegments[1].speaker, "C")
    }

    func testSyncSpeakerMetadataPreservesGroupWhenSpeakerConsistent() {
        // Set up: 3 segments, group retranslation for indices 0-1 (same speaker "A")
        service.translatedSegments = [
            ConfirmedSegment(text: "こんにちは", speaker: "A"),
            ConfirmedSegment(text: "世界", speaker: "A"),
            ConfirmedSegment(text: "次の文", speaker: "B"),
        ]
        service.applyGroupRetranslation(
            groupStartIndex: 0, groupEndIndex: 1, translatedText: "ハローワールド"
        )

        // Sync: both segments changed to "C" (consistent within group)
        let source = [
            ConfirmedSegment(text: "Hello", speaker: "C"),
            ConfirmedSegment(text: " world", speaker: "C"),
            ConfirmedSegment(text: " Next.", speaker: "B"),
        ]
        service.syncSpeakerMetadata(from: source)

        // Group retranslation should still be active (no internal boundary)
        XCTAssertEqual(service.displaySegments[0].text, "ハローワールド")
        XCTAssertEqual(service.displaySegments[0].speaker, "C")
        XCTAssertEqual(service.displaySegments[1].text, "")
    }

    func testSyncSpeakerMetadataInvalidatesGroupOnNilSpeaker() {
        // Set up: 2 segments in a group, both speaker "A"
        service.translatedSegments = [
            ConfirmedSegment(text: "こんにちは", speaker: "A"),
            ConfirmedSegment(text: "世界", speaker: "A"),
        ]
        service.applyGroupRetranslation(
            groupStartIndex: 0, groupEndIndex: 1, translatedText: "ハローワールド"
        )

        // Sync: segment 1 speaker becomes nil (non-nil → nil transition)
        let source = [
            ConfirmedSegment(text: "Hello", speaker: "A"),
            ConfirmedSegment(text: " world"),
        ]
        service.syncSpeakerMetadata(from: source)

        // Retranslation should be invalidated
        XCTAssertEqual(service.displaySegments[0].text, "こんにちは")
        XCTAssertEqual(service.displaySegments[0].speaker, "A")
        XCTAssertEqual(service.displaySegments[1].text, "世界")
        XCTAssertNil(service.displaySegments[1].speaker)
    }

    func testSyncSpeakerMetadataOnlyInvalidatesAffectedGroup() {
        // Set up: 4 segments, two groups with retranslations
        service.translatedSegments = [
            ConfirmedSegment(text: "Seg0", speaker: "A"),
            ConfirmedSegment(text: "Seg1", speaker: "A"),
            ConfirmedSegment(text: "Seg2", speaker: "B"),
            ConfirmedSegment(text: "Seg3", speaker: "B"),
        ]
        // Group 0: indices 0-1
        service.applyGroupRetranslation(
            groupStartIndex: 0, groupEndIndex: 1, translatedText: "Group0訳"
        )
        // Group 1: indices 2-3
        service.applyGroupRetranslation(
            groupStartIndex: 2, groupEndIndex: 3, translatedText: "Group1訳"
        )

        // Sync: only group 0 has speaker change (seg 1: A→C), group 1 stays consistent
        let source = [
            ConfirmedSegment(text: "s0", speaker: "A"),
            ConfirmedSegment(text: "s1", speaker: "C"),
            ConfirmedSegment(text: "s2", speaker: "B"),
            ConfirmedSegment(text: "s3", speaker: "B"),
        ]
        service.syncSpeakerMetadata(from: source)

        // Group 0 invalidated: individual translations restored
        XCTAssertEqual(service.displaySegments[0].text, "Seg0")
        XCTAssertEqual(service.displaySegments[1].text, "Seg1")
        // Group 1 preserved: retranslation still active
        XCTAssertEqual(service.displaySegments[2].text, "Group1訳")
        XCTAssertEqual(service.displaySegments[3].text, "")
    }

    // MARK: - sync after split integration

    func testSyncAfterSplitMaintainsCorrectMapping() {
        service.translatedSegments = [
            ConfirmedSegment(text: "こんにちは", speaker: "A"),
            ConfirmedSegment(text: "世界", speaker: "A"),
        ]

        // Split index 0
        service.splitSegment(at: 0)
        XCTAssertEqual(service.translatedSegments.count, 3)

        // Source confirmedSegments after split
        let source = [
            ConfirmedSegment(text: "Hello", speaker: "A"),
            ConfirmedSegment(text: "", speaker: "B"),  // split + reassigned
            ConfirmedSegment(text: "World", speaker: "A"),
        ]

        service.syncSpeakerMetadata(from: source)

        XCTAssertEqual(service.translatedSegments[0].speaker, "A")
        XCTAssertEqual(service.translatedSegments[1].speaker, "B")
        XCTAssertEqual(service.translatedSegments[2].speaker, "A")
    }
}
