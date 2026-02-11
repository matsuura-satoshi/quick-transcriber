import Foundation
import WhisperKit

public final class WhisperKitEngine: TranscriptionEngine {
    private var whisperKit: WhisperKit?
    private var streamTranscriber: AudioStreamTranscriber?
    private var _isStreaming = false

    public init() {}

    public var isStreaming: Bool {
        get async { _isStreaming }
    }

    public func setup(model: String) async throws {
        // Use cached model folder if available, otherwise download
        let modelFolder = Self.findCachedModelFolder(for: model)
        NSLog("[WhisperKitEngine] Model folder: \(modelFolder ?? "none, will download")")

        // Use cpuAndGPU to avoid slow ANE compilation
        let computeOptions = ModelComputeOptions(
            melCompute: .cpuAndGPU,
            audioEncoderCompute: .cpuAndGPU,
            textDecoderCompute: .cpuAndGPU,
            prefillCompute: .cpuAndGPU
        )

        let whisper: WhisperKit
        if let modelFolder {
            whisper = try await WhisperKit(
                modelFolder: modelFolder,
                computeOptions: computeOptions,
                verbose: true,
                logLevel: .info,
                load: true,
                download: false
            )
        } else {
            whisper = try await WhisperKit(
                model: model,
                computeOptions: computeOptions,
                verbose: true,
                logLevel: .info,
                load: true,
                download: true
            )
        }
        self.whisperKit = whisper
    }

    /// Stable model storage path under Application Support.
    private static var appModelBaseDir: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("MyTranscriber/Models")
    }

    /// Search for a cached model folder. First checks our stable App Support path,
    /// then known HuggingFace download locations.
    private static func findCachedModelFolder(for model: String) -> String? {
        let modelDirName = "openai_whisper-\(model)"
        let fm = FileManager.default
        let homeDir = fm.homeDirectoryForCurrentUser

        // Priority 1: Our stable Application Support path
        let stablePath = appModelBaseDir.appendingPathComponent(modelDirName)
        if fm.fileExists(atPath: stablePath.appendingPathComponent("AudioEncoder.mlmodelc").path) {
            return stablePath.path
        }

        // Priority 2: Known download locations
        let searchPaths = [
            homeDir.appendingPathComponent("Documents/huggingface/models/argmaxinc/whisperkit-coreml"),
            homeDir.appendingPathComponent("Library/Application Support/MacWhisper/models/whisperkit/models/argmaxinc/whisperkit-coreml"),
        ]

        for basePath in searchPaths {
            let candidateDir = basePath.appendingPathComponent(modelDirName)
            if fm.fileExists(atPath: candidateDir.appendingPathComponent("AudioEncoder.mlmodelc").path) {
                // Copy to stable path for consistent CoreML cache
                copyToStablePath(from: candidateDir, to: stablePath)
                return stablePath.path
            }
        }
        return nil
    }

    /// Copy model files to the stable Application Support path.
    private static func copyToStablePath(from source: URL, to destination: URL) {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.path) else { return }
        do {
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: source, to: destination)
            NSLog("[WhisperKitEngine] Copied model to stable path: \(destination.path)")
        } catch {
            NSLog("[WhisperKitEngine] Failed to copy model to stable path: \(error)")
        }
    }

    public func startStreaming(
        language: String,
        parameters: TranscriptionParameters = .default,
        onStateChange: @escaping @Sendable (TranscriptionState) -> Void
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
            let confirmedText = newState.confirmedSegments
                .map { Self.cleanSegmentText($0.text) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")

            let unconfirmedText = newState.unconfirmedSegments
                .map { Self.cleanSegmentText($0.text) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")

            let state = TranscriptionState(
                confirmedText: confirmedText,
                unconfirmedText: unconfirmedText,
                isRecording: newState.isRecording
            )
            onStateChange(state)
        }

        self.streamTranscriber = transcriber
        self._isStreaming = true
        try await transcriber.startStreamTranscription()
    }

    public func stopStreaming() async {
        await streamTranscriber?.stopStreamTranscription()
        self.streamTranscriber = nil
        self._isStreaming = false
    }

    public func cleanup() {
        Task {
            await stopStreaming()
        }
        whisperKit = nil
    }
}

extension WhisperKitEngine {
    public static func cleanSegmentText(_ text: String) -> String {
        var cleaned = text
        // Remove any remaining special tokens like <|...|>
        cleaned = cleaned.replacingOccurrences(
            of: "<\\|[^|]*\\|>",
            with: "",
            options: .regularExpression
        )
        // Remove Unicode replacement characters
        cleaned = cleaned.replacingOccurrences(of: "\u{FFFD}", with: "")
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum WhisperKitEngineError: LocalizedError {
    case notInitialized
    case tokenizerNotAvailable

    public var errorDescription: String? {
        switch self {
        case .notInitialized:
            return "WhisperKit is not initialized. Call setup() first."
        case .tokenizerNotAvailable:
            return "Tokenizer is not available. Model may not be loaded correctly."
        }
    }
}
