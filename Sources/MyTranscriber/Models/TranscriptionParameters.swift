import Foundation

public struct TranscriptionParameters: Codable, Sendable, Equatable {
    public var requiredSegmentsForConfirmation: Int
    public var silenceThreshold: Float
    public var compressionCheckWindow: Int
    public var useVAD: Bool
    public var temperature: Float
    public var temperatureFallbackCount: Int
    public var noSpeechThreshold: Float
    public var concurrentWorkerCount: Int
    public var compressionRatioThreshold: Float
    public var logProbThreshold: Float
    public var firstTokenLogProbThreshold: Float
    /// Max 224 for large-v3-turbo model (WhisperKit internal buffer limit)
    public var sampleLength: Int
    public var windowClipTime: Float

    public init(
        requiredSegmentsForConfirmation: Int = 1,
        silenceThreshold: Float = 0.5,
        compressionCheckWindow: Int = 20,
        useVAD: Bool = true,
        temperature: Float = 0.0,
        temperatureFallbackCount: Int = 0,
        noSpeechThreshold: Float = 0.4,
        concurrentWorkerCount: Int = 4,
        compressionRatioThreshold: Float = 2.4,
        logProbThreshold: Float = -1.0,
        firstTokenLogProbThreshold: Float = -1.5,
        sampleLength: Int = 224,
        windowClipTime: Float = 1.0
    ) {
        self.requiredSegmentsForConfirmation = requiredSegmentsForConfirmation
        self.silenceThreshold = silenceThreshold
        self.compressionCheckWindow = compressionCheckWindow
        self.useVAD = useVAD
        self.temperature = temperature
        self.temperatureFallbackCount = temperatureFallbackCount
        self.noSpeechThreshold = noSpeechThreshold
        self.concurrentWorkerCount = concurrentWorkerCount
        self.compressionRatioThreshold = compressionRatioThreshold
        self.logProbThreshold = logProbThreshold
        self.firstTokenLogProbThreshold = firstTokenLogProbThreshold
        self.sampleLength = sampleLength
        self.windowClipTime = windowClipTime
    }

    public static let `default` = TranscriptionParameters()

    /// Aggressive confirmation: disable all quality filters, confirm as fast as possible.
    /// Start here and tighten filters gradually.
    public static let aggressive = TranscriptionParameters(
        requiredSegmentsForConfirmation: 1,
        silenceThreshold: 0.2,
        compressionCheckWindow: 20,
        useVAD: true,
        temperature: 0.0,
        temperatureFallbackCount: 0,
        noSpeechThreshold: 1.0,       // never reject as no-speech
        concurrentWorkerCount: 4,
        compressionRatioThreshold: 5.0, // effectively disable
        logProbThreshold: -10.0,        // effectively disable
        firstTokenLogProbThreshold: -10.0, // effectively disable
        sampleLength: 224,
        windowClipTime: 0.5            // shorter window for faster confirmation
    )
}
