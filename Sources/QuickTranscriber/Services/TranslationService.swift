import Foundation
import Translation

@MainActor
public final class TranslationService: ObservableObject {
    @Published public var translatedSegments: [ConfirmedSegment] = []

    private var translationCursor: Int = 0

    public init() {}

    public func translateNewSegments(_ segments: [ConfirmedSegment], using session: TranslationSession) async {
        guard translationCursor < segments.count else { return }

        let newSegments = Array(segments[translationCursor...])
        let startCursor = translationCursor

        do {
            let requests = newSegments.enumerated().map { index, segment in
                TranslationSession.Request(
                    sourceText: segment.text,
                    clientIdentifier: "\(startCursor + index)"
                )
            }

            let responses = try await session.translations(from: requests)

            // Batch updates to avoid N separate @Published notifications
            var updated = translatedSegments
            for response in responses {
                guard let idStr = response.clientIdentifier,
                      let index = Int(idStr) else { continue }
                let sourceIndex = index - startCursor
                guard sourceIndex >= 0, sourceIndex < newSegments.count else { continue }

                let source = newSegments[sourceIndex]
                let translated = ConfirmedSegment(
                    text: response.targetText,
                    precedingSilence: source.precedingSilence,
                    speaker: source.speaker,
                    speakerConfidence: source.speakerConfidence,
                    isUserCorrected: source.isUserCorrected,
                    originalSpeaker: source.originalSpeaker,
                    speakerEmbedding: source.speakerEmbedding
                )

                let targetIndex = index
                if targetIndex < updated.count {
                    updated[targetIndex] = translated
                } else {
                    while updated.count < targetIndex {
                        updated.append(ConfirmedSegment(text: ""))
                    }
                    updated.append(translated)
                }
            }
            translatedSegments = updated

            translationCursor = startCursor + newSegments.count
        } catch {
            NSLog("[QuickTranscriber] Translation error: \(error)")
        }
    }

    public func syncSpeakerMetadata(from source: [ConfirmedSegment]) {
        let count = min(translatedSegments.count, source.count)
        guard count > 0 else { return }
        var updated = translatedSegments
        for i in 0..<count {
            updated[i].speaker = source[i].speaker
            updated[i].speakerConfidence = source[i].speakerConfidence
            updated[i].isUserCorrected = source[i].isUserCorrected
            updated[i].originalSpeaker = source[i].originalSpeaker
        }
        translatedSegments = updated
    }

    public func reset() {
        translatedSegments = []
        translationCursor = 0
    }
}
