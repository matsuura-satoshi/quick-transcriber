import Foundation

public final class ChunkedWhisperEngine: TranscriptionEngine {
    private let audioCaptureService: AudioCaptureService
    private let transcriber: ChunkTranscriber
    private var accumulator: ChunkAccumulator
    private var _isStreaming = false
    private var streamingTask: Task<Void, Never>?
    private var confirmedSegments: [String] = []
    private var streamContinuation: AsyncStream<[Float]>.Continuation?
    private var currentLanguage: String = "en"
    private var currentParameters: TranscriptionParameters = .default

    public init(
        audioCaptureService: AudioCaptureService = AVAudioCaptureService(),
        transcriber: ChunkTranscriber = WhisperKitChunkTranscriber()
    ) {
        self.audioCaptureService = audioCaptureService
        self.transcriber = transcriber
        self.accumulator = ChunkAccumulator()
    }

    public var isStreaming: Bool {
        get async { _isStreaming }
    }

    public func setup(model: String) async throws {
        try await transcriber.setup(model: model)
    }

    public func startStreaming(
        language: String,
        parameters: TranscriptionParameters = .default,
        onStateChange: @escaping @Sendable (TranscriptionState) -> Void
    ) async throws {
        accumulator = ChunkAccumulator(
            chunkDuration: parameters.chunkDuration,
            silenceCutoffDuration: parameters.silenceCutoffDuration,
            silenceEnergyThreshold: parameters.silenceEnergyThreshold
        )
        confirmedSegments = []
        currentLanguage = language
        currentParameters = parameters
        _isStreaming = true

        let (bufferStream, continuation) = AsyncStream<[Float]>.makeStream()
        self.streamContinuation = continuation

        try await audioCaptureService.startCapture { samples in
            continuation.yield(samples)
        }

        streamingTask = Task { [weak self] in
            for await samples in bufferStream {
                guard let self, self._isStreaming else { break }

                if let chunk = self.accumulator.appendBuffer(samples) {
                    await self.processChunk(chunk, onStateChange: onStateChange)
                }
            }
        }

        NSLog("[ChunkedWhisperEngine] Streaming started")
    }

    public func stopStreaming() async {
        _isStreaming = false
        audioCaptureService.stopCapture()

        // Finish the stream so for-await loop exits cleanly
        streamContinuation?.finish()
        streamContinuation = nil

        // Cancel and wait for task completion before touching shared state
        streamingTask?.cancel()
        await streamingTask?.value
        streamingTask = nil

        // Now safe to access accumulator — streaming task is fully stopped
        if let remainingChunk = accumulator.flush() {
            await processChunk(remainingChunk, onStateChange: { _ in })
        }

        accumulator.reset()
        NSLog("[ChunkedWhisperEngine] Streaming stopped. Total segments: \(confirmedSegments.count)")
    }

    public func cleanup() {
        Task { [weak self] in
            await self?.stopStreaming()
        }
    }

    // MARK: - Private

    /// RMS energy threshold for skipping silent chunks.
    /// Lower than ChunkAccumulator.silenceEnergyThreshold (0.01) to be more conservative.
    private static let silenceSkipThreshold: Float = 0.005

    private func processChunk(
        _ chunk: [Float],
        onStateChange: @escaping @Sendable (TranscriptionState) -> Void
    ) async {
        let chunkDuration = Double(chunk.count) / 16000.0
        let energy = ChunkAccumulator.rmsEnergy(of: chunk)

        if energy < Self.silenceSkipThreshold {
            NSLog("[ChunkedWhisperEngine] Skipping silent chunk: \(String(format: "%.1f", chunkDuration))s, energy=\(String(format: "%.6f", energy))")
            return
        }

        NSLog("[ChunkedWhisperEngine] Processing chunk: \(String(format: "%.1f", chunkDuration))s, \(chunk.count) samples, energy=\(String(format: "%.6f", energy))")

        do {
            let segments = try await transcriber.transcribe(
                audioArray: chunk,
                language: currentLanguage,
                parameters: currentParameters
            )
            let filtered = segments.filter { segment in
                if TranscriptionUtils.shouldFilterByMetadata(segment) {
                    NSLog("[ChunkedWhisperEngine] Filtered (metadata): \(segment.text) [noSpeech=\(String(format: "%.2f", segment.noSpeechProb)), logprob=\(String(format: "%.2f", segment.avgLogprob))]")
                    return false
                }
                if TranscriptionUtils.shouldFilterSegment(segment.text, language: currentLanguage) {
                    NSLog("[ChunkedWhisperEngine] Filtered (text): \(segment.text)")
                    return false
                }
                return true
            }
            confirmedSegments.append(contentsOf: filtered.map(\.text))
            for segment in filtered {
                NSLog("[ChunkedWhisperEngine] Confirmed: \(segment.text)")
            }

            let confirmedText = confirmedSegments.joined(separator: "\n")
            onStateChange(TranscriptionState(
                confirmedText: confirmedText,
                unconfirmedText: "",
                isRecording: true
            ))
        } catch {
            NSLog("[ChunkedWhisperEngine] Chunk transcription failed: \(error). Continuing...")
        }
    }
}
