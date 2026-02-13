import Foundation
import FluidAudio

/// Protocol for identifying the current speaker from an audio chunk.
public protocol SpeakerDiarizer: AnyObject, Sendable {
    func setup() async throws
    func identifySpeaker(audioChunk: [Float]) async -> String?
}

/// Speaker diarizer backed by FluidAudio's OfflineDiarizerManager.
/// Uses a rolling buffer (30-second window) to accumulate audio and diarize
/// the window. Identifies the speaker of the latest chunk using time-range
/// filtering and embedding-based cosine similarity tracking.
public final class FluidAudioSpeakerDiarizer: SpeakerDiarizer, @unchecked Sendable {
    /// Lightweight struct for testable segment info.
    public struct TimedSegmentInfo {
        public let speakerId: String
        public let embedding: [Float]
        public let startTime: Float
        public let endTime: Float

        public init(speakerId: String, embedding: [Float], startTime: Float, endTime: Float) {
            self.speakerId = speakerId
            self.embedding = embedding
            self.startTime = startTime
            self.endTime = endTime
        }
    }

    private let sampleRate: Int = 16000
    private let windowDuration: TimeInterval
    private var rollingBuffer: [Float] = []
    private var diarizer: OfflineDiarizerManager?
    private let speakerTracker: EmbeddingBasedSpeakerTracker
    private let lock = NSLock()

    public init(
        similarityThreshold: Float = 0.5,
        updateAlpha: Float = 0.3,
        windowDuration: TimeInterval = 30.0
    ) {
        self.windowDuration = windowDuration
        self.speakerTracker = EmbeddingBasedSpeakerTracker(
            similarityThreshold: similarityThreshold,
            updateAlpha: updateAlpha
        )
    }

    public func setup() async throws {
        let config = OfflineDiarizerConfig()
        let manager = OfflineDiarizerManager(config: config)
        try await manager.prepareModels()
        diarizer = manager
        NSLog("[SpeakerDiarizer] FluidAudio models prepared")
    }

    public func identifySpeaker(audioChunk: [Float]) async -> String? {
        guard let diarizer else { return nil }

        let windowSamples = Int(windowDuration * Double(sampleRate))
        let currentBuffer = lock.withLock {
            rollingBuffer.append(contentsOf: audioChunk)
            if rollingBuffer.count > windowSamples {
                rollingBuffer.removeFirst(rollingBuffer.count - windowSamples)
            }
            return rollingBuffer
        }

        // Need at least 1 second of audio for meaningful diarization
        guard currentBuffer.count >= sampleRate else { return nil }

        do {
            let result = try await diarizer.process(audio: currentBuffer)

            let segments = result.segments.map { seg in
                TimedSegmentInfo(
                    speakerId: seg.speakerId,
                    embedding: seg.embedding,
                    startTime: seg.startTimeSeconds,
                    endTime: seg.endTimeSeconds
                )
            }

            let bufferDuration = Float(currentBuffer.count) / Float(sampleRate)
            let chunkDuration = Float(audioChunk.count) / Float(sampleRate)

            guard let relevant = Self.findRelevantSegment(
                segments: segments,
                bufferDuration: bufferDuration,
                chunkDuration: chunkDuration
            ) else {
                return nil
            }

            let label = speakerTracker.identify(embedding: relevant.embedding)
            NSLog("[SpeakerDiarizer] Raw=\(relevant.speakerId) → Tracked=\(label) (time=\(String(format: "%.1f", relevant.startTime))-\(String(format: "%.1f", relevant.endTime))s)")
            return label
        } catch {
            NSLog("[SpeakerDiarizer] Diarization failed: \(error)")
            return nil
        }
    }

    /// Find the segment with the most overlap with the latest chunk's time range.
    public static func findRelevantSegment(
        segments: [TimedSegmentInfo],
        bufferDuration: Float,
        chunkDuration: Float
    ) -> TimedSegmentInfo? {
        let chunkStart = bufferDuration - chunkDuration
        let chunkEnd = bufferDuration

        var bestSegment: TimedSegmentInfo?
        var bestOverlap: Float = 0

        for segment in segments {
            let overlapStart = max(segment.startTime, chunkStart)
            let overlapEnd = min(segment.endTime, chunkEnd)
            let overlap = max(0, overlapEnd - overlapStart)

            if overlap > bestOverlap {
                bestOverlap = overlap
                bestSegment = segment
            }
        }

        return bestSegment
    }
}
