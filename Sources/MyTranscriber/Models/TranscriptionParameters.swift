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

    public init(
        temperature: Float = 0.0,
        temperatureFallbackCount: Int = 0,
        sampleLength: Int = 224,
        concurrentWorkerCount: Int = 4,
        chunkDuration: TimeInterval = 3.0,
        silenceCutoffDuration: TimeInterval = 0.8,
        silenceEnergyThreshold: Float = 0.01
    ) {
        self.temperature = temperature
        self.temperatureFallbackCount = temperatureFallbackCount
        self.sampleLength = sampleLength
        self.concurrentWorkerCount = concurrentWorkerCount
        self.chunkDuration = chunkDuration
        self.silenceCutoffDuration = silenceCutoffDuration
        self.silenceEnergyThreshold = silenceEnergyThreshold
    }

    public static let `default` = TranscriptionParameters()
}
