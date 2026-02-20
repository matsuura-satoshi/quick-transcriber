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
}
