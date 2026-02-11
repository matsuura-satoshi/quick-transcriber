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

    private func processChunk(
        _ chunk: [Float],
        onStateChange: @escaping @Sendable (TranscriptionState) -> Void
    ) async {
        let chunkDuration = Double(chunk.count) / 16000.0
        NSLog("[ChunkedWhisperEngine] Processing chunk: \(String(format: "%.1f", chunkDuration))s, \(chunk.count) samples")

        do {
            let texts = try await transcriber.transcribe(
                audioArray: chunk,
                language: currentLanguage,
                parameters: currentParameters
            )
            confirmedSegments.append(contentsOf: texts)
            for text in texts {
                NSLog("[ChunkedWhisperEngine] Confirmed: \(text)")
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
