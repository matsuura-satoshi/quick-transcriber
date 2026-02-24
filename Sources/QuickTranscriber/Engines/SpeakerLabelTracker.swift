import Foundation

/// Forward-only Viterbi speaker smoother that replaces the threshold-based
/// SpeakerLabelTracker. Maintains log-probabilities for each known speaker
/// and uses a transition model (stayProbability) combined with observation
/// confidence to decide when a speaker change is real vs. a false alarm.
///
/// During pending state (potential speaker change being evaluated), returns
/// nil so callers can defer labeling and retroactively update segments once
/// the new speaker is confirmed.
public final class ViterbiSpeakerSmoother: @unchecked Sendable {
    private let stayProbability: Double

    // Viterbi state: log-probabilities for each known speaker
    private var stateLogProb: [UUID: Double] = [:]
    private var confirmed: SpeakerIdentification?
    private var pendingSpeakerId: UUID?
    private var pendingCount: Int = 0
    private var immediateConfirmNext: Bool = false

    public init(stayProbability: Double = 0.9) {
        self.stayProbability = max(0.5, min(stayProbability, 0.999))
    }

    /// Process a raw speaker identification from the diarizer.
    ///
    /// - Returns: The confirmed speaker identification, or nil if a potential
    ///   speaker change is still being evaluated (pending).
    public func process(_ identification: SpeakerIdentification?) -> SpeakerIdentification? {
        guard let id = identification else {
            return confirmed
        }

        // First speaker: confirm immediately
        guard confirmed != nil else {
            stateLogProb[id.speakerId] = 0.0
            confirmed = id
            pendingSpeakerId = nil
            pendingCount = 0
            return id
        }

        // After silence reset: confirm next observation immediately
        if immediateConfirmNext {
            immediateConfirmNext = false
            stateLogProb = [id.speakerId: 0.0]
            confirmed = id
            pendingSpeakerId = nil
            pendingCount = 0
            return id
        }

        let currentConfirmed = confirmed!

        // Clamp confidence to avoid log(0)
        let c = Double(min(max(id.confidence, 0.01), 0.99))

        // Register new speaker if not seen before
        if stateLogProb[id.speakerId] == nil {
            stateLogProb[id.speakerId] = -100.0
        }

        let N = Double(stateLogProb.count)
        let logStay = log(stayProbability)
        let logSwitch = log((1.0 - stayProbability) / max(N - 1.0, 1.0))

        // Observation model
        let logObsMatch = log(c)
        let logObsNoMatch = log((1.0 - c) / max(N - 1.0, 1.0))

        // Viterbi update
        var newLogProb: [UUID: Double] = [:]
        for targetSpeaker in stateLogProb.keys {
            var bestLogProb = -Double.infinity
            for (sourceSpeaker, sourceProb) in stateLogProb {
                let logTrans = (sourceSpeaker == targetSpeaker) ? logStay : logSwitch
                let candidate = sourceProb + logTrans
                if candidate > bestLogProb {
                    bestLogProb = candidate
                }
            }
            let logObs = (targetSpeaker == id.speakerId) ? logObsMatch : logObsNoMatch
            newLogProb[targetSpeaker] = bestLogProb + logObs
        }

        // Normalize to prevent underflow
        let maxLogProb = newLogProb.values.max() ?? 0.0
        for key in newLogProb.keys {
            newLogProb[key, default: 0] -= maxLogProb
        }
        stateLogProb = newLogProb

        // Find best speaker
        guard let bestEntry = stateLogProb.max(by: { $0.value < $1.value }) else {
            return confirmed
        }
        let bestSpeaker = bestEntry.key

        // Decision logic
        if bestSpeaker == currentConfirmed.speakerId {
            // Same speaker still winning - return confirmed with updated confidence
            if id.speakerId == currentConfirmed.speakerId {
                confirmed = id
            }
            pendingSpeakerId = nil
            pendingCount = 0
            let active = confirmed ?? currentConfirmed
            return SpeakerIdentification(
                speakerId: active.speakerId,
                confidence: id.speakerId == currentConfirmed.speakerId ? id.confidence : active.confidence,
                embedding: id.speakerId == currentConfirmed.speakerId ? id.embedding : active.embedding
            )
        } else {
            // Different speaker is winning in Viterbi
            if bestSpeaker == pendingSpeakerId {
                pendingCount += 1
            } else {
                pendingSpeakerId = bestSpeaker
                pendingCount = 1
            }

            // Require 1 step of stability before confirming
            if pendingCount >= 2 {
                confirmed = SpeakerIdentification(
                    speakerId: bestSpeaker,
                    confidence: id.confidence,
                    embedding: id.embedding
                )
                pendingSpeakerId = nil
                pendingCount = 0
                return confirmed
            }

            return nil  // Pending
        }
    }

    /// Reset transition bias while preserving speaker knowledge.
    /// After significant silence, treats next observation as fresh start
    /// so that any speaker (new or returning) confirms immediately.
    public func resetForSpeakerChange() {
        pendingSpeakerId = nil
        pendingCount = 0
        immediateConfirmNext = true
        // confirmed is preserved for nil-input fallback
    }

    public func reset() {
        stateLogProb = [:]
        confirmed = nil
        pendingSpeakerId = nil
        pendingCount = 0
        immediateConfirmNext = false
    }
}

// Backward compatibility alias
public typealias SpeakerLabelTracker = ViterbiSpeakerSmoother
