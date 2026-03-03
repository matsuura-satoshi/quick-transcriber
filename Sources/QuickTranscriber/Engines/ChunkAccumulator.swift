import Foundation

/// Result of a chunk cut, containing audio samples and silence info.
public struct ChunkResult: Sendable {
    public let samples: [Float]
    public let trailingSilenceDuration: TimeInterval
    public let precedingSilenceDuration: TimeInterval

    public init(samples: [Float], trailingSilenceDuration: TimeInterval, precedingSilenceDuration: TimeInterval = 0) {
        self.samples = samples
        self.trailingSilenceDuration = trailingSilenceDuration
        self.precedingSilenceDuration = precedingSilenceDuration
    }
}

// MARK: - VADChunkAccumulator

/// VAD-driven chunk accumulator using a state machine (Idle/Speaking/Hangover).
/// Emits chunks at natural utterance boundaries based on energy detection with hysteresis.
public struct VADChunkAccumulator: Sendable {
    // MARK: - Configuration

    /// Maximum chunk duration before forced cut (seconds).
    public var maxChunkDuration: TimeInterval
    /// Silence duration after speech to trigger chunk emission (seconds).
    public var endOfUtteranceSilence: TimeInterval
    /// RMS energy threshold below which audio is considered silence (offset threshold).
    public var silenceEnergyThreshold: Float
    /// RMS energy threshold to start speech detection (onset threshold, higher than offset for hysteresis).
    public var speechOnsetThreshold: Float
    /// Duration of audio to retain before speech onset (seconds).
    public var preRollDuration: TimeInterval
    /// Grace period after energy drops below offset before transitioning to silence (seconds).
    public var hangoverDuration: TimeInterval
    /// Minimum net speech duration for a chunk to be emitted (seconds).
    public var minimumUtteranceDuration: TimeInterval

    // MARK: - Internal State

    private enum State {
        case idle
        case speaking
        case hangover
    }

    private let sampleRate: Double = Constants.Audio.sampleRate
    private var state: State = .idle
    private var speechBuffer: [Float] = []
    private var preRollRing: RingBuffer
    /// Accumulated silence while in idle state (seconds).
    private var silenceDurationInIdle: TimeInterval = 0
    /// Accumulated silence at end of speech (seconds).
    private var trailingSilenceInSpeech: TimeInterval = 0
    /// Time elapsed in hangover state (seconds).
    private var hangoverElapsed: TimeInterval = 0
    /// Net speech duration in current utterance (excluding trailing silence).
    private var netSpeechDuration: TimeInterval = 0
    /// Preceding silence to assign to next emitted chunk (carryover from previous trailing).
    private var pendingPrecedingSilence: TimeInterval = 0

    // MARK: - Init

    public init(
        maxChunkDuration: TimeInterval = Constants.VAD.defaultMaxChunkDuration,
        endOfUtteranceSilence: TimeInterval = Constants.VAD.defaultEndOfUtteranceSilence,
        silenceEnergyThreshold: Float = Constants.VAD.defaultSilenceEnergyThreshold,
        speechOnsetThreshold: Float = Constants.VAD.defaultSpeechOnsetThreshold,
        preRollDuration: TimeInterval = Constants.VAD.defaultPreRollDuration,
        hangoverDuration: TimeInterval = Constants.VAD.defaultHangoverDuration,
        minimumUtteranceDuration: TimeInterval = Constants.VAD.defaultMinimumUtteranceDuration
    ) {
        self.maxChunkDuration = maxChunkDuration
        self.endOfUtteranceSilence = endOfUtteranceSilence
        self.silenceEnergyThreshold = silenceEnergyThreshold
        self.speechOnsetThreshold = speechOnsetThreshold
        self.preRollDuration = preRollDuration
        self.hangoverDuration = hangoverDuration
        self.minimumUtteranceDuration = minimumUtteranceDuration
        let preRollCapacity = Int(preRollDuration * Constants.Audio.sampleRate)
        self.preRollRing = RingBuffer(capacity: preRollCapacity)
    }

    // MARK: - Public API

    /// Append a buffer of 16kHz Float32 samples.
    /// Returns a ChunkResult if an utterance boundary is detected, otherwise nil.
    public mutating func appendBuffer(_ samples: [Float]) -> ChunkResult? {
        guard !samples.isEmpty else { return nil }

        let energy = Self.rmsEnergy(of: samples)
        let bufferDuration = TimeInterval(samples.count) / sampleRate

        switch state {
        case .idle:
            return processIdle(samples: samples, energy: energy, duration: bufferDuration)
        case .speaking:
            return processSpeaking(samples: samples, energy: energy, duration: bufferDuration)
        case .hangover:
            return processHangover(samples: samples, energy: energy, duration: bufferDuration)
        }
    }

    /// Flush any remaining audio (e.g., when stopping recording).
    public mutating func flush() -> ChunkResult? {
        switch state {
        case .idle:
            return nil
        case .speaking, .hangover:
            guard !speechBuffer.isEmpty else {
                transitionToIdle()
                return nil
            }
            let totalDuration = TimeInterval(speechBuffer.count) / sampleRate
            guard totalDuration >= 0.5 else {
                transitionToIdle()
                return nil
            }
            return emitChunk()
        }
    }

    /// Reset the accumulator, discarding all buffered audio.
    public mutating func reset() {
        state = .idle
        speechBuffer.removeAll(keepingCapacity: true)
        preRollRing = RingBuffer(capacity: Int(preRollDuration * sampleRate))
        silenceDurationInIdle = 0
        trailingSilenceInSpeech = 0
        hangoverElapsed = 0
        netSpeechDuration = 0
        pendingPrecedingSilence = 0
    }

    /// Calculate RMS energy of a sample buffer.
    public static func rmsEnergy(of samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sumOfSquares = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return (sumOfSquares / Float(samples.count)).squareRoot()
    }

    // MARK: - State Processors

    private mutating func processIdle(samples: [Float], energy: Float, duration: TimeInterval) -> ChunkResult? {
        if energy >= speechOnsetThreshold {
            // Transition to speaking
            state = .speaking
            // Copy pre-roll into speech buffer
            speechBuffer = preRollRing.drain()
            speechBuffer.append(contentsOf: samples)
            // Record preceding silence (idle silence + any carryover)
            pendingPrecedingSilence += silenceDurationInIdle
            silenceDurationInIdle = 0
            trailingSilenceInSpeech = 0
            netSpeechDuration = duration
            preRollRing = RingBuffer(capacity: Int(preRollDuration * sampleRate))
            return nil
        }

        // Still idle — update pre-roll ring and silence counter
        preRollRing.write(samples)
        silenceDurationInIdle += duration
        return nil
    }

    private mutating func processSpeaking(samples: [Float], energy: Float, duration: TimeInterval) -> ChunkResult? {
        speechBuffer.append(contentsOf: samples)

        if energy < silenceEnergyThreshold {
            // Energy below offset → enter hangover
            trailingSilenceInSpeech += duration
            hangoverElapsed = duration
            state = .hangover
            return checkEmitConditions()
        }

        // Still speaking
        trailingSilenceInSpeech = 0
        netSpeechDuration += duration
        return checkMaxDuration()
    }

    private mutating func processHangover(samples: [Float], energy: Float, duration: TimeInterval) -> ChunkResult? {
        speechBuffer.append(contentsOf: samples)

        if energy >= silenceEnergyThreshold {
            // Speech resumed — back to speaking
            state = .speaking
            hangoverElapsed = 0
            trailingSilenceInSpeech = 0
            netSpeechDuration += duration
            return checkMaxDuration()
        }

        // Still silent in hangover
        trailingSilenceInSpeech += duration
        hangoverElapsed += duration
        return checkEmitConditions()
    }

    // MARK: - Emission Logic

    private mutating func checkEmitConditions() -> ChunkResult? {
        // End of utterance: trailing silence exceeds threshold
        if trailingSilenceInSpeech >= endOfUtteranceSilence {
            return emitOrDiscard()
        }
        // Also check max duration
        return checkMaxDuration()
    }

    private mutating func checkMaxDuration() -> ChunkResult? {
        let totalDuration = TimeInterval(speechBuffer.count) / sampleRate
        if totalDuration >= maxChunkDuration {
            return emitOrDiscard()
        }
        return nil
    }

    private mutating func emitOrDiscard() -> ChunkResult? {
        if netSpeechDuration < minimumUtteranceDuration {
            // Too short — discard
            let trailing = trailingSilenceInSpeech
            transitionToIdle()
            // Carry over the silence
            pendingPrecedingSilence += trailing
            return nil
        }
        return emitChunk()
    }

    private mutating func emitChunk() -> ChunkResult {
        let chunk = speechBuffer
        let trailing = trailingSilenceInSpeech
        let preceding = pendingPrecedingSilence

        // Reset for next utterance
        speechBuffer.removeAll(keepingCapacity: true)
        state = .idle
        preRollRing = RingBuffer(capacity: Int(preRollDuration * sampleRate))
        silenceDurationInIdle = 0
        trailingSilenceInSpeech = 0
        hangoverElapsed = 0
        netSpeechDuration = 0
        // Carry over trailing silence as pending preceding for next chunk
        pendingPrecedingSilence = trailing

        return ChunkResult(
            samples: chunk,
            trailingSilenceDuration: trailing,
            precedingSilenceDuration: preceding
        )
    }

    private mutating func transitionToIdle() {
        state = .idle
        speechBuffer.removeAll(keepingCapacity: true)
        preRollRing = RingBuffer(capacity: Int(preRollDuration * sampleRate))
        trailingSilenceInSpeech = 0
        hangoverElapsed = 0
        netSpeechDuration = 0
        silenceDurationInIdle = 0
    }
}

// MARK: - RingBuffer

extension VADChunkAccumulator {
    /// Fixed-capacity ring buffer for pre-roll audio samples.
    struct RingBuffer: Sendable {
        private var storage: [Float]
        private var writeIndex: Int = 0
        private var count: Int = 0
        let capacity: Int

        init(capacity: Int) {
            self.capacity = max(capacity, 0)
            self.storage = capacity > 0 ? [Float](repeating: 0, count: capacity) : []
        }

        /// Write samples into the ring buffer, overwriting oldest data if full.
        mutating func write(_ samples: [Float]) {
            guard capacity > 0 else { return }
            for sample in samples {
                storage[writeIndex] = sample
                writeIndex = (writeIndex + 1) % capacity
                if count < capacity {
                    count += 1
                }
            }
        }

        /// Drain all samples in order (oldest first) and reset.
        mutating func drain() -> [Float] {
            guard count > 0 else { return [] }
            var result = [Float]()
            result.reserveCapacity(count)
            if count < capacity {
                // Buffer not yet full — data starts at 0
                result.append(contentsOf: storage[0..<count])
            } else {
                // Buffer full — read from writeIndex (oldest) to end, then start to writeIndex
                result.append(contentsOf: storage[writeIndex..<capacity])
                if writeIndex > 0 {
                    result.append(contentsOf: storage[0..<writeIndex])
                }
            }
            count = 0
            writeIndex = 0
            return result
        }
    }
}
