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
    private var stateLogProb: [String: Double] = [:]
    private var confirmedLabel: String?
    private var confirmedIdentification: SpeakerIdentification?
    private var pendingLabel: String?
    private var pendingCount: Int = 0

    public init(stayProbability: Double = 0.9) {
        self.stayProbability = max(0.5, min(stayProbability, 0.999))
    }

    /// Process a raw speaker identification from the diarizer.
    ///
    /// - Returns: The confirmed speaker identification, or nil if a potential
    ///   speaker change is still being evaluated (pending).
    public func processLabel(_ identification: SpeakerIdentification?) -> SpeakerIdentification? {
        guard let id = identification else {
            return confirmedIdentification
        }

        // First speaker: confirm immediately
        if confirmedLabel == nil {
            stateLogProb[id.label] = 0.0
            confirmedLabel = id.label
            confirmedIdentification = id
            pendingLabel = nil
            pendingCount = 0
            return id
        }

        // Clamp confidence to avoid log(0)
        let c = Double(min(max(id.confidence, 0.01), 0.99))

        // Register new speaker if not seen before
        if stateLogProb[id.label] == nil {
            stateLogProb[id.label] = -100.0
        }

        let N = Double(stateLogProb.count)
        let logStay = log(stayProbability)
        let logSwitch = log((1.0 - stayProbability) / max(N - 1.0, 1.0))

        // Observation model
        let logObsMatch = log(c)
        let logObsNoMatch = log((1.0 - c) / max(N - 1.0, 1.0))

        // Viterbi update
        var newLogProb: [String: Double] = [:]
        for targetSpeaker in stateLogProb.keys {
            var bestLogProb = -Double.infinity
            for (sourceSpeaker, sourceProb) in stateLogProb {
                let logTrans = (sourceSpeaker == targetSpeaker) ? logStay : logSwitch
                let candidate = sourceProb + logTrans
                if candidate > bestLogProb {
                    bestLogProb = candidate
                }
            }
            let logObs = (targetSpeaker == id.label) ? logObsMatch : logObsNoMatch
            newLogProb[targetSpeaker] = bestLogProb + logObs
        }

        // Normalize to prevent underflow
        let maxLogProb = newLogProb.values.max() ?? 0.0
        for key in newLogProb.keys {
            newLogProb[key]! -= maxLogProb
        }
        stateLogProb = newLogProb

        // Find best speaker
        let bestSpeaker = stateLogProb.max(by: { $0.value < $1.value })!.key

        // Decision logic
        if bestSpeaker == confirmedLabel {
            // Same speaker still winning - return confirmed with updated confidence
            confirmedIdentification = id.label == confirmedLabel ? id : confirmedIdentification
            pendingLabel = nil
            pendingCount = 0
            return SpeakerIdentification(
                label: confirmedLabel!,
                confidence: id.label == confirmedLabel ? id.confidence : confirmedIdentification!.confidence,
                embedding: id.label == confirmedLabel ? id.embedding : confirmedIdentification?.embedding
            )
        } else {
            // Different speaker is winning in Viterbi
            if bestSpeaker == pendingLabel {
                pendingCount += 1
            } else {
                pendingLabel = bestSpeaker
                pendingCount = 1
            }

            // Require 1 step of stability before confirming
            if pendingCount >= 2 {
                confirmedLabel = bestSpeaker
                confirmedIdentification = SpeakerIdentification(
                    label: bestSpeaker,
                    confidence: id.confidence,
                    embedding: id.embedding
                )
                pendingLabel = nil
                pendingCount = 0
                return confirmedIdentification
            }

            return nil  // Pending
        }
    }

    public func reset() {
        stateLogProb = [:]
        confirmedLabel = nil
        confirmedIdentification = nil
        pendingLabel = nil
        pendingCount = 0
    }
}

// Backward compatibility alias
public typealias SpeakerLabelTracker = ViterbiSpeakerSmoother
