import Foundation
import WhisperKit

/// WhisperKitの機能をProtocol化して、テストでモック可能にする。
public protocol WhisperKitProviding: AnyObject {
    func setup(model: String) async throws
    func startStreamTranscription(
        language: String,
        parameters: TranscriptionParameters,
        onSegmentChange: @escaping @Sendable (_ confirmed: [String], _ unconfirmed: [String]) -> Void
    ) async throws
    func stopStreamTranscription() async
}

public final class DefaultWhisperKitProvider: WhisperKitProviding {
    private var whisperKit: WhisperKit?
    private var streamTranscriber: AudioStreamTranscriber?

    public init() {}

    public func setup(model: String) async throws {
        self.whisperKit = try await WhisperKitModelLoader.createWhisperKit(model: model)
    }

    public func startStreamTranscription(
        language: String,
        parameters: TranscriptionParameters,
        onSegmentChange: @escaping @Sendable (_ confirmed: [String], _ unconfirmed: [String]) -> Void
    ) async throws {
        guard let whisperKit else {
            throw WhisperKitEngineError.notInitialized
        }
        guard let tokenizer = whisperKit.tokenizer else {
            throw WhisperKitEngineError.tokenizerNotAvailable
        }

        let decodingOptions = DecodingOptions(
            task: .transcribe,
            language: language,
            temperature: parameters.temperature,
            temperatureFallbackCount: parameters.temperatureFallbackCount,
            sampleLength: parameters.sampleLength,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            compressionRatioThreshold: parameters.compressionRatioThreshold,
            logProbThreshold: parameters.logProbThreshold,
            firstTokenLogProbThreshold: parameters.firstTokenLogProbThreshold,
            noSpeechThreshold: parameters.noSpeechThreshold,
            concurrentWorkerCount: parameters.concurrentWorkerCount,
            chunkingStrategy: .vad
        )

        let transcriber = AudioStreamTranscriber(
            audioEncoder: whisperKit.audioEncoder,
            featureExtractor: whisperKit.featureExtractor,
            segmentSeeker: whisperKit.segmentSeeker,
            textDecoder: whisperKit.textDecoder,
            tokenizer: tokenizer,
            audioProcessor: whisperKit.audioProcessor,
            decodingOptions: decodingOptions,
            requiredSegmentsForConfirmation: parameters.requiredSegmentsForConfirmation,
            silenceThreshold: parameters.silenceThreshold,
            compressionCheckWindow: parameters.compressionCheckWindow,
            useVAD: parameters.useVAD
        ) { oldState, newState in
            let confirmed = newState.confirmedSegments.map { $0.text }
            let unconfirmed = newState.unconfirmedSegments.map { $0.text }
            onSegmentChange(confirmed, unconfirmed)
        }

        self.streamTranscriber = transcriber
        try await transcriber.startStreamTranscription()
    }

    public func stopStreamTranscription() async {
        await streamTranscriber?.stopStreamTranscription()
        streamTranscriber = nil
    }
}
