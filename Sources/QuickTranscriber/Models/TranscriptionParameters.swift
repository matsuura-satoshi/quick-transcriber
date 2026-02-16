import Foundation

public struct TranscriptionParameters: Codable, Sendable, Equatable {
    public var temperature: Float
    public var temperatureFallbackCount: Int
    /// Max 224 for large-v3-turbo model (WhisperKit internal buffer limit)
    public var sampleLength: Int
    public var concurrentWorkerCount: Int

    // Chunked engine parameters
    public var chunkDuration: TimeInterval
    public var silenceCutoffDuration: TimeInterval
    public var silenceEnergyThreshold: Float

    // Line break parameters
    public var silenceLineBreakThreshold: TimeInterval

    // Speaker diarization
    public var enableSpeakerDiarization: Bool

    public init(
        temperature: Float = 0.0,
        temperatureFallbackCount: Int = 0,
        sampleLength: Int = 224,
        concurrentWorkerCount: Int = 4,
        chunkDuration: TimeInterval = 5.0,
        silenceCutoffDuration: TimeInterval = 0.8,
        silenceEnergyThreshold: Float = 0.01,
        silenceLineBreakThreshold: TimeInterval = 1.0,
        enableSpeakerDiarization: Bool = false
    ) {
        self.temperature = temperature
        self.temperatureFallbackCount = temperatureFallbackCount
        self.sampleLength = sampleLength
        self.concurrentWorkerCount = concurrentWorkerCount
        self.chunkDuration = chunkDuration
        self.silenceCutoffDuration = silenceCutoffDuration
        self.silenceEnergyThreshold = silenceEnergyThreshold
        self.silenceLineBreakThreshold = silenceLineBreakThreshold
        self.enableSpeakerDiarization = enableSpeakerDiarization
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
        silenceLineBreakThreshold = try container.decodeIfPresent(TimeInterval.self, forKey: .silenceLineBreakThreshold) ?? 1.0
        enableSpeakerDiarization = try container.decodeIfPresent(Bool.self, forKey: .enableSpeakerDiarization) ?? false
    }

    public static let `default` = TranscriptionParameters()
}
