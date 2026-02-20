import Foundation

public final class ChunkedWhisperEngine: TranscriptionEngine {
    private let audioCaptureService: AudioCaptureService
    private let transcriber: ChunkTranscriber
    private let diarizer: SpeakerDiarizer?
    private let speakerProfileStore: SpeakerProfileStore?
    private let embeddingHistoryStore: EmbeddingHistoryStore?
    private var accumulator: ChunkAccumulator
    private var _isStreaming = false
    private var streamingTask: Task<Void, Never>?
    private var confirmedSegments: [ConfirmedSegment] = []
    private var speakerSmoother = ViterbiSpeakerSmoother()
    private var pendingSegmentStartIndex: Int?
    private var streamContinuation: AsyncStream<[Float]>.Continuation?
    private var currentLanguage: String = "en"
    private var currentParameters: TranscriptionParameters = .default
    /// Accumulated silence since last confirmed segment (seconds).
    private var silenceSinceLastSegment: TimeInterval = 0

    public init(
        audioCaptureService: AudioCaptureService = AVAudioCaptureService(),
        transcriber: ChunkTranscriber = WhisperKitChunkTranscriber(),
        diarizer: SpeakerDiarizer? = nil,
        speakerProfileStore: SpeakerProfileStore? = nil,
        embeddingHistoryStore: EmbeddingHistoryStore? = nil
    ) {
        self.audioCaptureService = audioCaptureService
        self.transcriber = transcriber
        self.diarizer = diarizer
        self.speakerProfileStore = speakerProfileStore
        self.embeddingHistoryStore = embeddingHistoryStore
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
        participantProfiles: [(label: String, embedding: [Float])]? = nil,
        onStateChange: @escaping @Sendable (TranscriptionState) -> Void
    ) async throws {
        accumulator = ChunkAccumulator(
            chunkDuration: parameters.chunkDuration,
            silenceCutoffDuration: parameters.silenceCutoffDuration,
            silenceEnergyThreshold: parameters.silenceEnergyThreshold
        )
        confirmedSegments = []
        speakerSmoother = ViterbiSpeakerSmoother(stayProbability: parameters.speakerTransitionPenalty)
        if let diarizer, parameters.enableSpeakerDiarization {
            if let participantProfiles, parameters.diarizationMode == .manual {
                // Manual mode: load only participant embeddings
                if !participantProfiles.isEmpty {
                    diarizer.loadSpeakerProfiles(participantProfiles)
                    NSLog("[ChunkedWhisperEngine] Manual mode: loaded \(participantProfiles.count) participant profiles")
                }
                diarizer.updateExpectedSpeakerCount(participantProfiles.count)
            } else {
                // Auto mode: load all profiles from store
                diarizer.updateExpectedSpeakerCount(parameters.expectedSpeakerCount)
                if let store = speakerProfileStore {
                    let profiles = store.profiles.map { ($0.label, $0.embedding) }
                    if !profiles.isEmpty {
                        diarizer.loadSpeakerProfiles(profiles)
                        NSLog("[ChunkedWhisperEngine] Auto mode: loaded \(profiles.count) speaker profiles from store")
                    }
                }
            }
        } else {
            diarizer?.updateExpectedSpeakerCount(parameters.expectedSpeakerCount)
        }
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
        if let diarizer, currentParameters.enableSpeakerDiarization, let store = speakerProfileStore {
            let sessionProfiles = diarizer.exportSpeakerProfiles()
            if !sessionProfiles.isEmpty {
                // Filter out profiles for speakers that were user-corrected
                let correctedOriginalSpeakers = Set(
                    confirmedSegments
                        .filter { $0.isUserCorrected }
                        .compactMap { $0.originalSpeaker }
                )
                let filteredProfiles: [(label: String, embedding: [Float])]
                if correctedOriginalSpeakers.isEmpty {
                    filteredProfiles = sessionProfiles
                } else {
                    filteredProfiles = sessionProfiles.filter { !correctedOriginalSpeakers.contains($0.label) }
                    NSLog("[ChunkedWhisperEngine] Skipping merge for corrected speakers: \(correctedOriginalSpeakers)")
                }
                if !filteredProfiles.isEmpty {
                    store.mergeSessionProfiles(filteredProfiles)
                    do {
                        try store.save()
                    } catch {
                        NSLog("[ChunkedWhisperEngine] Failed to save speaker profiles: \(error)")
                    }
                    NSLog("[ChunkedWhisperEngine] Saved \(filteredProfiles.count) speaker profiles to store (filtered \(sessionProfiles.count - filteredProfiles.count))")
                }
            }
        }
        // Save embedding history for future profile reconstruction
        if let historyStore = embeddingHistoryStore, let diarizer, currentParameters.enableSpeakerDiarization {
            let detailed = diarizer.exportDetailedSpeakerProfiles()
            let entries = detailed.compactMap { profile -> EmbeddingHistoryEntry? in
                guard !profile.embeddingHistory.isEmpty else { return nil }
                // Match with stored profile to get UUID
                let storedProfile = speakerProfileStore?.profiles.first { $0.label == profile.label }
                let profileId = storedProfile?.id ?? UUID()
                return EmbeddingHistoryEntry(
                    speakerProfileId: profileId,
                    label: profile.label,
                    sessionDate: Date(),
                    embeddings: profile.embeddingHistory.map { entry in
                        HistoricalEmbedding(embedding: entry.embedding, confirmed: true, confidence: entry.confidence)
                    }
                )
            }
            if !entries.isEmpty {
                historyStore.appendSession(entries: entries)
                NSLog("[ChunkedWhisperEngine] Saved \(entries.count) speaker histories")
            }
        }
        NSLog("[ChunkedWhisperEngine] Streaming stopped. Total segments: \(confirmedSegments.count)")
    }

    public var currentConfirmedSegments: [ConfirmedSegment] {
        confirmedSegments
    }

    public func markSegmentAsUserCorrected(at index: Int, speaker: String, originalSpeaker: String? = nil) {
        guard index < confirmedSegments.count else { return }
        let orig = originalSpeaker ?? confirmedSegments[index].speaker
        confirmedSegments[index].originalSpeaker = orig
        confirmedSegments[index].speaker = speaker
        confirmedSegments[index].speakerConfidence = 1.0
        confirmedSegments[index].isUserCorrected = true
    }

    public func correctSpeakerAssignment(embedding: [Float], from oldLabel: String, to newLabel: String) {
        diarizer?.correctSpeakerAssignment(embedding: embedding, from: oldLabel, to: newLabel)
    }

    public func cleanup() {
        Task { [weak self] in
            await self?.stopStreaming()
        }
    }

    // MARK: - Private

    /// RMS energy threshold for skipping silent chunks.
    /// Lower than ChunkAccumulator.silenceEnergyThreshold (0.01) to be more conservative.
    private static let silenceSkipThreshold: Float = Constants.Audio.silenceSkipThreshold

    private func processChunk(
        _ chunkResult: ChunkResult,
        onStateChange: @escaping @Sendable (TranscriptionState) -> Void
    ) async {
        let chunk = chunkResult.samples
        let chunkDuration = Double(chunk.count) / Constants.Audio.sampleRate
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
            let rawSpeakerResult: SpeakerIdentification?
            if let diarizer, currentParameters.enableSpeakerDiarization {
                async let transcription = transcriber.transcribe(
                    audioArray: chunk,
                    language: currentLanguage,
                    parameters: currentParameters
                )
                async let speakerId = diarizer.identifySpeaker(audioChunk: chunk)
                segments = try await transcription
                rawSpeakerResult = await speakerId
            } else {
                segments = try await transcriber.transcribe(
                    audioArray: chunk,
                    language: currentLanguage,
                    parameters: currentParameters
                )
                rawSpeakerResult = nil
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
            let smoothedResult: SpeakerIdentification?
            if currentParameters.enableSpeakerDiarization {
                smoothedResult = speakerSmoother.processLabel(rawSpeakerResult)

                // Retroactively update pending segments with confidence (skip user-corrected)
                if let result = smoothedResult, let startIdx = pendingSegmentStartIndex {
                    for i in startIdx..<confirmedSegments.count {
                        guard !confirmedSegments[i].isUserCorrected else { continue }
                        confirmedSegments[i].speaker = result.label
                        confirmedSegments[i].speakerConfidence = result.confidence
                    }
                    pendingSegmentStartIndex = nil
                    NSLog("[ChunkedWhisperEngine] Retroactively assigned speaker \(result.label) to \(confirmedSegments.count - startIdx) pending segments")
                }
            } else {
                smoothedResult = nil
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
                    speaker: smoothedResult?.label,
                    speakerConfidence: smoothedResult?.confidence,
                    speakerEmbedding: rawSpeakerResult?.embedding
                ))
                NSLog("[ChunkedWhisperEngine] Confirmed: \(segment.text) (precedingSilence=\(String(format: "%.1f", precedingSilence))s, speaker=\(smoothedResult?.label ?? "pending"), conf=\(smoothedResult.map { String(format: "%.3f", $0.confidence) } ?? "n/a"))")
            }

            // Track where pending segments start
            if currentParameters.enableSpeakerDiarization && smoothedResult == nil
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
                isRecording: true,
                confirmedSegments: confirmedSegments
            ))
        } catch {
            NSLog("[ChunkedWhisperEngine] Chunk transcription failed: \(error). Continuing...")
        }
    }
}
