import Foundation

public final class ChunkedWhisperEngine: TranscriptionEngine {
    private let audioCaptureService: AudioCaptureService
    private let transcriber: ChunkTranscriber
    private let diarizer: SpeakerDiarizer?
    private var accumulator: ChunkAccumulator
    private var _isStreaming = false
    private var streamingTask: Task<Void, Never>?
    private var confirmedSegments: [ConfirmedSegment] = []
    private let speakerTracker = SpeakerLabelTracker()
    private var pendingSegmentStartIndex: Int?
    private var streamContinuation: AsyncStream<[Float]>.Continuation?
    private var currentLanguage: String = "en"
    private var currentParameters: TranscriptionParameters = .default
    /// Accumulated silence since last confirmed segment (seconds).
    private var silenceSinceLastSegment: TimeInterval = 0

    public init(
        audioCaptureService: AudioCaptureService = AVAudioCaptureService(),
        transcriber: ChunkTranscriber = WhisperKitChunkTranscriber(),
        diarizer: SpeakerDiarizer? = nil
    ) {
        self.audioCaptureService = audioCaptureService
        self.transcriber = transcriber
        self.diarizer = diarizer
        self.accumulator = ChunkAccumulator()
    }

    public var isStreaming: Bool {
        get async { _isStreaming }
    }

    public func setup(model: String) async throws {
        // Initialize WhisperKit and FluidAudio in parallel
        if let diarizer {
            async let whisperSetup: Void = transcriber.setup(model: model)
            async let diarizerSetup: Void = diarizer.setup()
            try await whisperSetup
            do {
                try await diarizerSetup
                NSLog("[ChunkedWhisperEngine] Speaker diarizer ready")
            } catch {
                NSLog("[ChunkedWhisperEngine] Speaker diarizer failed to initialize: \(error). Continuing without diarization.")
            }
        } else {
            try await transcriber.setup(model: model)
        }
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
        speakerTracker.reset()
        diarizer?.updateExpectedSpeakerCount(parameters.expectedSpeakerCount)
        pendingSegmentStartIndex = nil
        silenceSinceLastSegment = 0
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

                if let chunkResult = self.accumulator.appendBuffer(samples) {
                    await self.processChunk(chunkResult, onStateChange: onStateChange)
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
        if let remainingResult = accumulator.flush() {
            await processChunk(remainingResult, onStateChange: { _ in })
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
        _ chunkResult: ChunkResult,
        onStateChange: @escaping @Sendable (TranscriptionState) -> Void
    ) async {
        let chunk = chunkResult.samples
        let chunkDuration = Double(chunk.count) / 16000.0
        let energy = ChunkAccumulator.rmsEnergy(of: chunk)

        if energy < Self.silenceSkipThreshold {
            // Silent chunk: accumulate its full duration as silence
            silenceSinceLastSegment += chunkDuration
            NSLog("[ChunkedWhisperEngine] Skipping silent chunk: \(String(format: "%.1f", chunkDuration))s, energy=\(String(format: "%.6f", energy)), totalSilence=\(String(format: "%.1f", silenceSinceLastSegment))s")
            return
        }

        NSLog("[ChunkedWhisperEngine] Processing chunk: \(String(format: "%.1f", chunkDuration))s, \(chunk.count) samples, energy=\(String(format: "%.6f", energy))")

        do {
            // Run transcription and diarization in parallel when diarizer is available
            let segments: [TranscribedSegment]
            let rawSpeakerLabel: String?
            if let diarizer, currentParameters.enableSpeakerDiarization {
                async let transcription = transcriber.transcribe(
                    audioArray: chunk,
                    language: currentLanguage,
                    parameters: currentParameters
                )
                async let speakerId = diarizer.identifySpeaker(audioChunk: chunk)
                segments = try await transcription
                rawSpeakerLabel = await speakerId
            } else {
                segments = try await transcriber.transcribe(
                    audioArray: chunk,
                    language: currentLanguage,
                    parameters: currentParameters
                )
                rawSpeakerLabel = nil
            }
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

            // Speaker label smoothing: require consecutive confirmation before accepting change
            let smoothedSpeaker: String?
            if currentParameters.enableSpeakerDiarization {
                smoothedSpeaker = speakerTracker.processLabel(rawSpeakerLabel)

                // Retroactively update pending segments when speaker is confirmed
                if let speaker = smoothedSpeaker, let startIdx = pendingSegmentStartIndex {
                    for i in startIdx..<confirmedSegments.count {
                        confirmedSegments[i].speaker = speaker
                    }
                    pendingSegmentStartIndex = nil
                    NSLog("[ChunkedWhisperEngine] Retroactively assigned speaker \(speaker) to \(confirmedSegments.count - startIdx) pending segments")
                }
            } else {
                smoothedSpeaker = nil
            }

            for (index, segment) in filtered.enumerated() {
                let precedingSilence: TimeInterval
                if index == 0 {
                    precedingSilence = silenceSinceLastSegment
                } else {
                    precedingSilence = 0
                }
                confirmedSegments.append(ConfirmedSegment(
                    text: segment.text,
                    precedingSilence: precedingSilence,
                    speaker: smoothedSpeaker
                ))
                NSLog("[ChunkedWhisperEngine] Confirmed: \(segment.text) (precedingSilence=\(String(format: "%.1f", precedingSilence))s, speaker=\(smoothedSpeaker ?? "pending"))")
            }

            // Track where pending segments start
            if currentParameters.enableSpeakerDiarization && smoothedSpeaker == nil
                && pendingSegmentStartIndex == nil && !filtered.isEmpty {
                pendingSegmentStartIndex = confirmedSegments.count - filtered.count
            }

            // Reset silence tracker: start with trailing silence from this chunk
            silenceSinceLastSegment = chunkResult.trailingSilenceDuration

            let confirmedText = TranscriptionUtils.joinSegments(
                confirmedSegments,
                language: currentLanguage,
                silenceThreshold: currentParameters.silenceLineBreakThreshold
            )
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
