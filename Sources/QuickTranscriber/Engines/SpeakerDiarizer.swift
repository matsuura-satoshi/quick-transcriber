import Foundation
import FluidAudio

/// Protocol for identifying the current speaker from an audio chunk.
public protocol SpeakerDiarizer: AnyObject, Sendable {
    func setup() async throws
    func identifySpeaker(audioChunk: [Float], forceRun: Bool) async -> SpeakerIdentification?
    func updateExpectedSpeakerCount(_ count: Int?)
    func exportSpeakerProfiles() -> [(speakerId: UUID, embedding: [Float])]
    func exportDetailedSpeakerProfiles() -> [(speakerId: UUID, embedding: [Float], embeddingHistory: [WeightedEmbedding])]
    func loadSpeakerProfiles(_ profiles: [(speakerId: UUID, embedding: [Float])])
    func correctSpeakerAssignment(embedding: [Float], from oldId: UUID, to newId: UUID)
}

extension SpeakerDiarizer {
    public func identifySpeaker(audioChunk: [Float]) async -> SpeakerIdentification? {
        await identifySpeaker(audioChunk: audioChunk, forceRun: false)
    }
}

/// Speaker diarizer backed by FluidAudio's OfflineDiarizerManager.
/// Uses a rolling buffer to accumulate audio and diarize the window.
/// Identifies the speaker of the latest chunk using time-range filtering
/// and embedding-based cosine similarity tracking.
///
/// To reduce label flips, diarization only runs when enough audio has been
/// accumulated (controlled by `diarizationChunkDuration`). Between runs,
/// the last known speaker identification result is returned.
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

    private let sampleRate: Int = Constants.Audio.sampleRateInt
    private let windowDuration: TimeInterval
    private var rollingBuffer: [Float] = []
    private var diarizer: OfflineDiarizerManager?
    private let speakerTracker: EmbeddingBasedSpeakerTracker
    private var pacer: DiarizationPacer
    private let lock = NSLock()

    public init(
        similarityThreshold: Float = Constants.Embedding.similarityThreshold,
        updateAlpha: Float = 0.3,
        windowDuration: TimeInterval = 15.0,
        diarizationChunkDuration: TimeInterval = 7.0,
        expectedSpeakerCount: Int? = nil,
        profileStrategy: ProfileStrategy = .none
    ) {
        self.windowDuration = windowDuration
        self.speakerTracker = EmbeddingBasedSpeakerTracker(
            similarityThreshold: similarityThreshold,
            updateAlpha: updateAlpha,
            expectedSpeakerCount: expectedSpeakerCount,
            strategy: profileStrategy
        )
        self.pacer = DiarizationPacer(
            diarizationChunkDuration: diarizationChunkDuration,
            sampleRate: Constants.Audio.sampleRateInt
        )
    }

    public func updateExpectedSpeakerCount(_ count: Int?) {
        speakerTracker.expectedSpeakerCount = count
    }

    public func setup() async throws {
        let config = OfflineDiarizerConfig()
        let manager = OfflineDiarizerManager(config: config)
        try await manager.prepareModels()
        diarizer = manager
        NSLog("[SpeakerDiarizer] FluidAudio models prepared")
    }

    public func identifySpeaker(audioChunk: [Float], forceRun: Bool) async -> SpeakerIdentification? {
        guard let diarizer else { return nil }

        let windowSamples = Int(windowDuration * Double(sampleRate))
        let (currentBuffer, shouldRunDiarization, accumulatedDuration) = lock.withLock {
            rollingBuffer.append(contentsOf: audioChunk)
            if rollingBuffer.count > windowSamples {
                rollingBuffer.removeFirst(rollingBuffer.count - windowSamples)
            }
            let shouldRun = pacer.accumulate(chunkSamples: audioChunk.count)
            let accumulated = Float(pacer.samplesSinceLastDiarization) / Float(sampleRate)
            return (rollingBuffer, shouldRun, accumulated)
        }

        // Return cached result while accumulating (bypass when forced)
        guard shouldRunDiarization || forceRun else {
            return lock.withLock { pacer.lastResult }
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

            guard let relevant = Self.findRelevantSegment(
                segments: segments,
                bufferDuration: bufferDuration,
                chunkDuration: accumulatedDuration
            ) else {
                lock.withLock { pacer.reset() }
                return lock.withLock { pacer.lastResult }
            }

            let identification = speakerTracker.identify(embedding: relevant.embedding)
            lock.withLock {
                pacer.lastResult = identification
                pacer.reset()
            }
            NSLog("[SpeakerDiarizer] Raw=\(relevant.speakerId) → Tracked=\(identification.speakerId.uuidString) conf=\(String(format: "%.3f", identification.confidence)) (time=\(String(format: "%.1f", relevant.startTime))-\(String(format: "%.1f", relevant.endTime))s, accumulated=\(String(format: "%.1f", accumulatedDuration))s)")
            return identification
        } catch {
            NSLog("[SpeakerDiarizer] Diarization failed: \(error)")
            lock.withLock { pacer.reset() }
            return lock.withLock { pacer.lastResult }
        }
    }

    public func exportSpeakerProfiles() -> [(speakerId: UUID, embedding: [Float])] {
        speakerTracker.exportProfiles().map { ($0.speakerId, $0.embedding) }
    }

    public func exportDetailedSpeakerProfiles() -> [(speakerId: UUID, embedding: [Float], embeddingHistory: [WeightedEmbedding])] {
        speakerTracker.exportDetailedProfiles().map { ($0.speakerId, $0.embedding, $0.embeddingHistory) }
    }

    public func loadSpeakerProfiles(_ profiles: [(speakerId: UUID, embedding: [Float])]) {
        speakerTracker.loadProfiles(profiles)
        lock.withLock {
            rollingBuffer = []
            pacer = DiarizationPacer(
                diarizationChunkDuration: pacer.diarizationChunkDuration,
                sampleRate: sampleRate
            )
        }
    }

    public func correctSpeakerAssignment(embedding: [Float], from oldId: UUID, to newId: UUID) {
        speakerTracker.correctAssignment(embedding: embedding, from: oldId, to: newId)
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
