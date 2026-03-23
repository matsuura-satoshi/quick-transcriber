import Foundation

public enum DiarizationMode: String, Codable, Sendable, CaseIterable {
    case manual  // Fixed participant list (participant count = speaker count)
    case auto    // Existing behavior (load all profiles, auto-detect)
}

public struct TranscriptionParameters: Codable, Sendable, Equatable {
    public var temperature: Float
    public var temperatureFallbackCount: Int
    /// Max 224 for large-v3-turbo model (WhisperKit internal buffer limit)
    public var sampleLength: Int
    public var concurrentWorkerCount: Int

    // Chunked engine parameters (VAD-driven)
    public var chunkDuration: TimeInterval
    public var silenceCutoffDuration: TimeInterval
    public var silenceEnergyThreshold: Float
    public var speechOnsetThreshold: Float
    public var preRollDuration: TimeInterval
    public var hangoverDuration: TimeInterval

    // Line break parameters
    public var silenceLineBreakThreshold: TimeInterval

    // Speaker diarization
    public var enableSpeakerDiarization: Bool
    /// Expected number of speakers (nil = auto-detect, unlimited)
    public var expectedSpeakerCount: Int?
    /// Viterbi speaker smoothing: probability of staying with the same speaker (0.0-1.0)
    public var speakerTransitionPenalty: Double
    public var diarizationMode: DiarizationMode

    // WhisperKit quality thresholds (nil = disabled, used for file mode)
    public var compressionRatioThreshold: Float?
    public var logProbThreshold: Float?
    public var firstTokenLogProbThreshold: Float?
    public var noSpeechThreshold: Float?
    public var suppressBlank: Bool
    /// Minimum chunk duration (seconds) to apply quality thresholds.
    /// Chunks shorter than this use nil thresholds (safe for padded mel spectrograms).
    public var qualityThresholdMinChunkDuration: TimeInterval

    public init(
        temperature: Float = 0.0,
        temperatureFallbackCount: Int = 0,
        sampleLength: Int = 224,
        concurrentWorkerCount: Int = 4,
        chunkDuration: TimeInterval = Constants.VAD.defaultMaxChunkDuration,
        silenceCutoffDuration: TimeInterval = Constants.VAD.defaultEndOfUtteranceSilence,
        silenceEnergyThreshold: Float = Constants.VAD.defaultSilenceEnergyThreshold,
        speechOnsetThreshold: Float = Constants.VAD.defaultSpeechOnsetThreshold,
        preRollDuration: TimeInterval = Constants.VAD.defaultPreRollDuration,
        hangoverDuration: TimeInterval = Constants.VAD.defaultHangoverDuration,
        silenceLineBreakThreshold: TimeInterval = 1.0,
        enableSpeakerDiarization: Bool = false,
        expectedSpeakerCount: Int? = nil,
        speakerTransitionPenalty: Double = 0.8,
        diarizationMode: DiarizationMode = .auto,
        compressionRatioThreshold: Float? = nil,
        logProbThreshold: Float? = nil,
        firstTokenLogProbThreshold: Float? = nil,
        noSpeechThreshold: Float? = nil,
        suppressBlank: Bool = false,
        qualityThresholdMinChunkDuration: TimeInterval = Constants.FileTranscription.qualityThresholdMinChunkDuration
    ) {
        self.temperature = temperature
        self.temperatureFallbackCount = temperatureFallbackCount
        self.sampleLength = sampleLength
        self.concurrentWorkerCount = concurrentWorkerCount
        self.chunkDuration = chunkDuration
        self.silenceCutoffDuration = silenceCutoffDuration
        self.silenceEnergyThreshold = silenceEnergyThreshold
        self.speechOnsetThreshold = speechOnsetThreshold
        self.preRollDuration = preRollDuration
        self.hangoverDuration = hangoverDuration
        self.silenceLineBreakThreshold = silenceLineBreakThreshold
        self.enableSpeakerDiarization = enableSpeakerDiarization
        self.expectedSpeakerCount = expectedSpeakerCount
        self.speakerTransitionPenalty = speakerTransitionPenalty
        self.diarizationMode = diarizationMode
        self.compressionRatioThreshold = compressionRatioThreshold
        self.logProbThreshold = logProbThreshold
        self.firstTokenLogProbThreshold = firstTokenLogProbThreshold
        self.noSpeechThreshold = noSpeechThreshold
        self.suppressBlank = suppressBlank
        self.qualityThresholdMinChunkDuration = qualityThresholdMinChunkDuration
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        temperature = try container.decode(Float.self, forKey: .temperature)
        temperatureFallbackCount = try container.decode(Int.self, forKey: .temperatureFallbackCount)
        sampleLength = try container.decode(Int.self, forKey: .sampleLength)
        concurrentWorkerCount = try container.decode(Int.self, forKey: .concurrentWorkerCount)
        chunkDuration = try container.decode(TimeInterval.self, forKey: .chunkDuration)
        silenceCutoffDuration = try container.decode(TimeInterval.self, forKey: .silenceCutoffDuration)
        silenceEnergyThreshold = try container.decode(Float.self, forKey: .silenceEnergyThreshold)
        speechOnsetThreshold = try container.decodeIfPresent(Float.self, forKey: .speechOnsetThreshold) ?? Constants.VAD.defaultSpeechOnsetThreshold
        preRollDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .preRollDuration) ?? Constants.VAD.defaultPreRollDuration
        hangoverDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .hangoverDuration) ?? Constants.VAD.defaultHangoverDuration
        silenceLineBreakThreshold = try container.decodeIfPresent(TimeInterval.self, forKey: .silenceLineBreakThreshold) ?? 1.0
        enableSpeakerDiarization = try container.decodeIfPresent(Bool.self, forKey: .enableSpeakerDiarization) ?? false
        expectedSpeakerCount = try container.decodeIfPresent(Int.self, forKey: .expectedSpeakerCount)
        speakerTransitionPenalty = try container.decodeIfPresent(Double.self, forKey: .speakerTransitionPenalty) ?? 0.9
        diarizationMode = try container.decodeIfPresent(DiarizationMode.self, forKey: .diarizationMode) ?? .auto
        compressionRatioThreshold = try container.decodeIfPresent(Float.self, forKey: .compressionRatioThreshold)
        logProbThreshold = try container.decodeIfPresent(Float.self, forKey: .logProbThreshold)
        firstTokenLogProbThreshold = try container.decodeIfPresent(Float.self, forKey: .firstTokenLogProbThreshold)
        noSpeechThreshold = try container.decodeIfPresent(Float.self, forKey: .noSpeechThreshold)
        suppressBlank = try container.decodeIfPresent(Bool.self, forKey: .suppressBlank) ?? false
        qualityThresholdMinChunkDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .qualityThresholdMinChunkDuration) ?? Constants.FileTranscription.qualityThresholdMinChunkDuration
    }

    public static let `default` = TranscriptionParameters()
}
