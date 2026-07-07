import Foundation

public actor ChunkedWhisperEngine: TranscriptionEngine {
    private let audioCaptureService: AudioCaptureService
    private let transcriber: ChunkTranscriber
    private let diarizer: SpeakerDiarizer?
    private let speakerProfileStore: SpeakerProfileStore?
    private let embeddingHistoryStore: EmbeddingHistoryStore?
    private var accumulator: VADChunkAccumulator
    private var normalizer = AudioLevelNormalizer()
    private var _isStreaming = false
    private var streamingTask: Task<Void, Never>?
    private var confirmedSegments: [ConfirmedSegment] = []
    private var speakerSmoother = ViterbiSpeakerSmoother()
    private var pendingSegmentStartIndex: Int?
    private var streamContinuation: AsyncStream<[Float]>.Continuation?
    private var currentLanguage: String = "en"
    private var currentParameters: TranscriptionParameters = .default
    private var currentParticipantIds: Set<UUID> = []
    /// Whether diarization is active for this streaming session.
    private var diarizationActive = false
    private var audioRecorder: AudioRecordingService?

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
        self.accumulator = VADChunkAccumulator()
    }

    public var isStreaming: Bool { _isStreaming }

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
        participantProfiles: [(speakerId: UUID, embedding: [Float])]? = nil,
        audioRecordingDirectory: URL? = nil,
        audioRecordingDatePrefix: String? = nil,
        onStateChange: @escaping @Sendable (TranscriptionState) -> Void
    ) async throws {
        accumulator = VADChunkAccumulator(
            maxChunkDuration: parameters.chunkDuration,
            endOfUtteranceSilence: parameters.silenceCutoffDuration,
            silenceEnergyThreshold: parameters.silenceEnergyThreshold,
            speechOnsetThreshold: parameters.speechOnsetThreshold,
            preRollDuration: parameters.preRollDuration,
            hangoverDuration: parameters.hangoverDuration
        )
        normalizer = AudioLevelNormalizer()
        confirmedSegments = []
        currentParticipantIds = []
        speakerSmoother = ViterbiSpeakerSmoother(stayProbability: parameters.speakerTransitionPenalty)
        if let diarizer, parameters.enableSpeakerDiarization {
            if let participantProfiles, parameters.diarizationMode == .manual {
                // Manual mode: load only participant embeddings
                if participantProfiles.isEmpty {
                    diarizationActive = false
                    NSLog("[ChunkedWhisperEngine] Manual mode: no participants, diarization disabled")
                } else {
                    diarizationActive = true
                    diarizer.loadSpeakerProfiles(participantProfiles)
                    currentParticipantIds = Set(participantProfiles.map { $0.speakerId })
                    NSLog("[ChunkedWhisperEngine] Manual mode: loaded \(participantProfiles.count) participant profiles")
                }
                diarizer.updateExpectedSpeakerCount(participantProfiles.count)
                diarizer.setSuppressLearning(true)
            } else {
                // Auto mode: load all profiles from store
                diarizationActive = true
                diarizer.setSuppressLearning(false)
                diarizer.updateExpectedSpeakerCount(parameters.expectedSpeakerCount)
                if let store = speakerProfileStore {
                    let profiles = store.profiles.map { (speakerId: $0.id, embedding: $0.embedding) }
                    if !profiles.isEmpty {
                        diarizer.loadSpeakerProfiles(profiles)
                        NSLog("[ChunkedWhisperEngine] Auto mode: loaded \(profiles.count) speaker profiles from store")
                    }
                }
            }
        } else {
            diarizationActive = false
            diarizer?.updateExpectedSpeakerCount(parameters.expectedSpeakerCount)
        }
        pendingSegmentStartIndex = nil
        currentLanguage = language
        currentParameters = parameters
        _isStreaming = true

        // Start audio recording if configured
        if let recordingDir = audioRecordingDirectory, let datePrefix = audioRecordingDatePrefix {
            let recorder = AudioRecordingService()
            recorder.startSession(directory: recordingDir, datePrefix: datePrefix)
            audioRecorder = recorder
            NSLog("[ChunkedWhisperEngine] Audio recording started: %@", datePrefix)
        }

        let (bufferStream, continuation) = AsyncStream<[Float]>.makeStream()
        self.streamContinuation = continuation

        try await audioCaptureService.startCapture { samples in
            continuation.yield(samples)
        }

        streamingTask = Task { [weak self] in
            for await samples in bufferStream {
                guard let self else { break }
                guard await self.ingest(samples, onStateChange: onStateChange) else { break }
            }
        }

        NSLog("[ChunkedWhisperEngine] Streaming started")
    }

    public func stopStreaming(speakerDisplayNames: [String: String]) async {
        await stopStreaming(speakerDisplayNames: speakerDisplayNames, drainRemaining: false)
    }

    /// - Parameter drainRemaining: true ならバッファ済み全サンプルを処理してから停止する
    ///   （file 転写の完了時）。false なら即時停止（live 録音、file 転写のキャンセル）。
    public func stopStreaming(speakerDisplayNames: [String: String], drainRemaining: Bool) async {
        audioCaptureService.stopCapture()

        if drainRemaining {
            // Finish the stream and let the loop drain all buffered samples
            streamContinuation?.finish()
            streamContinuation = nil
            await streamingTask?.value
            streamingTask = nil
            _isStreaming = false
        } else {
            // Stop immediately
            _isStreaming = false
            streamContinuation?.finish()
            streamContinuation = nil
            streamingTask?.cancel()
            await streamingTask?.value
            streamingTask = nil
        }

        // Finalize audio recording
        if let recorder = audioRecorder {
            recorder.endSession()
            audioRecorder = nil
            NSLog("[ChunkedWhisperEngine] Audio recording saved")
        }

        if let remainingResult = accumulator.flush() {
            await processChunk(remainingResult, onStateChange: { _ in })
        }

        accumulator.reset()
        if let diarizer, diarizationActive {
            let finalizer = SessionLearningFinalizer(
                profileStore: speakerProfileStore,
                embeddingHistoryStore: embeddingHistoryStore
            )
            finalizer.finalize(
                mode: currentParameters.diarizationMode,
                participantIds: currentParticipantIds,
                segments: confirmedSegments,
                speakerDisplayNames: speakerDisplayNames,
                sessionProfiles: diarizer.exportSpeakerProfiles(),
                detailedProfiles: diarizer.exportDetailedSpeakerProfiles()
            )
        }
        currentParticipantIds = []
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

    public func correctSpeakerAssignment(embedding: [Float], from oldId: UUID, to newId: UUID) {
        diarizer?.correctSpeakerAssignment(embedding: embedding, from: oldId, to: newId)
        if speakerSmoother.confirmedSpeakerId == oldId {
            speakerSmoother.confirmSpeaker(newId)
        }
    }

    public func syncViterbiConfirm(to newId: UUID) {
        speakerSmoother.confirmSpeaker(newId)
    }

    public func mergeSpeakerProfiles(from sourceId: UUID, into targetId: UUID) {
        diarizer?.mergeSpeakerProfiles(from: sourceId, into: targetId)
        speakerSmoother.remapSpeaker(from: sourceId, to: targetId)
    }

    // MARK: - Private

    /// Streaming task から呼ばれる 1 バッファ分の取り込み。actor 隔離により
    /// normalizer / accumulator / confirmedSegments へのアクセスが直列化される。
    /// - Returns: false なら停止済みで、呼び出し側はループを抜ける。
    private func ingest(
        _ samples: [Float],
        onStateChange: @escaping @Sendable (TranscriptionState) -> Void
    ) async -> Bool {
        guard _isStreaming else { return false }
        let normalizedSamples = normalizer.normalize(samples)
        audioRecorder?.appendSamples(normalizedSamples)
        if let chunkResult = accumulator.appendBuffer(normalizedSamples) {
            await processChunk(chunkResult, onStateChange: onStateChange)
        }
        return true
    }

    private func processChunk(
        _ chunkResult: ChunkResult,
        onStateChange: @escaping @Sendable (TranscriptionState) -> Void
    ) async {
        let chunk = chunkResult.samples
        let utteranceId = chunkResult.utteranceId
        let chunkDuration = Double(chunk.count) / Constants.Audio.sampleRate

        LatencyInstrumentation.mark(.chunkDispatched, utteranceId: utteranceId)

        do {
            // Run transcription and diarization in parallel when diarizer is available
            let segments: [TranscribedSegment]
            let rawSpeakerResult: SpeakerIdentification?
            if let diarizer, diarizationActive {
                let significantSilence = chunkResult.precedingSilenceDuration >= currentParameters.silenceCutoffDuration
                if significantSilence {
                    speakerSmoother.resetForSpeakerChange()
                }
                async let transcription = transcriber.transcribe(
                    audioArray: chunk,
                    language: currentLanguage,
                    parameters: currentParameters,
                    utteranceId: utteranceId
                )
                async let speakerId = diarizer.identifySpeaker(
                    audioChunk: chunk,
                    forceRun: significantSilence,
                    utteranceId: utteranceId
                )
                segments = try await transcription
                rawSpeakerResult = await speakerId
            } else {
                segments = try await transcriber.transcribe(
                    audioArray: chunk,
                    language: currentLanguage,
                    parameters: currentParameters,
                    utteranceId: utteranceId
                )
                rawSpeakerResult = nil
            }
            let filtered = segments.filter { segment in
                if TranscriptionUtils.shouldFilterByMetadata(segment) { return false }
                if TranscriptionUtils.shouldFilterSegment(segment.text, language: currentLanguage) { return false }
                return true
            }

            // Speaker label smoothing: require consecutive confirmation before accepting change
            let smoothedResult: SpeakerIdentification?
            if diarizationActive {
                smoothedResult = speakerSmoother.process(rawSpeakerResult)

                // Retroactively update pending segments with confidence (skip user-corrected)
                if let result = smoothedResult, let startIdx = pendingSegmentStartIndex {
                    for i in startIdx..<confirmedSegments.count {
                        guard !confirmedSegments[i].isUserCorrected else { continue }
                        confirmedSegments[i].speaker = result.speakerId.uuidString
                        confirmedSegments[i].speakerConfidence = result.confidence
                    }
                    pendingSegmentStartIndex = nil
                    NSLog("[ChunkedWhisperEngine] Retroactively assigned speaker \(result.speakerId.uuidString) to \(confirmedSegments.count - startIdx) pending segments")
                }
            } else {
                smoothedResult = nil
            }

            for (index, segment) in filtered.enumerated() {
                let precedingSilence: TimeInterval
                if index == 0 {
                    precedingSilence = chunkResult.precedingSilenceDuration
                } else {
                    precedingSilence = 0
                }
                confirmedSegments.append(ConfirmedSegment(
                    text: segment.text,
                    precedingSilence: precedingSilence,
                    speaker: smoothedResult?.speakerId.uuidString,
                    speakerConfidence: smoothedResult?.confidence,
                    speakerEmbedding: rawSpeakerResult?.embedding
                ))
            }

            // Track where pending segments start
            if diarizationActive && smoothedResult == nil
                && pendingSegmentStartIndex == nil && !filtered.isEmpty {
                pendingSegmentStartIndex = confirmedSegments.count - filtered.count
            }

            LatencyInstrumentation.mark(.emitToUI, utteranceId: utteranceId)
            NSLog("[ChunkedWhisperEngine] Chunk %.1fs: +%d segments (%d filtered), speaker=%@, precedingSilence=%.1fs",
                  chunkDuration,
                  filtered.count,
                  segments.count - filtered.count,
                  smoothedResult?.speakerId.uuidString ?? "pending",
                  chunkResult.precedingSilenceDuration)
            onStateChange(TranscriptionState(
                unconfirmedText: "",
                isRecording: true,
                confirmedSegments: confirmedSegments
            ))
        } catch {
            NSLog("[ChunkedWhisperEngine] Chunk transcription failed: \(error). Continuing...")
        }
    }
}
