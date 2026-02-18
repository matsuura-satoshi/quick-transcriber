import Foundation

/// Smooths raw speaker labels from the diarizer by requiring N consecutive
/// identical labels before confirming a speaker change.
///
/// During the evaluation period, returns nil so that segments can be created
/// without speaker labels. When confirmed, the caller retroactively updates
/// pending segments.
///
/// Based on the temporal smoothing pattern from diart (Coria et al., 2021).
public final class SpeakerLabelTracker: @unchecked Sendable {
    private let confirmationThreshold: Int
    private var confirmedResult: SpeakerIdentification?
    private var pendingLabel: String?
    private var pendingCount: Int = 0
    private let lock = NSLock()

    public init(confirmationThreshold: Int = 2) {
        self.confirmationThreshold = max(1, confirmationThreshold)
    }

    /// Process a raw speaker identification from the diarizer.
    ///
    /// - Returns: The confirmed speaker identification (with confidence), or nil
    ///   if a potential speaker change is still being evaluated (pending).
    public func processLabel(_ identification: SpeakerIdentification?) -> SpeakerIdentification? {
        lock.withLock {
            _processLabel(identification)
        }
    }

    private func _processLabel(_ identification: SpeakerIdentification?) -> SpeakerIdentification? {
        guard let id = identification else {
            return confirmedResult
        }

        // First speaker: confirm immediately
        if confirmedResult == nil {
            confirmedResult = id
            pendingLabel = nil
            pendingCount = 0
            return id
        }

        // Same as confirmed: update with latest confidence, reset pending state
        if id.label == confirmedResult?.label {
            confirmedResult = id
            pendingLabel = nil
            pendingCount = 0
            return id
        }

        // Different from confirmed: evaluate
        if id.label == pendingLabel {
            pendingCount += 1
        } else {
            pendingLabel = id.label
            pendingCount = 1
        }

        if pendingCount >= confirmationThreshold {
            confirmedResult = id
            pendingLabel = nil
            pendingCount = 0
            return id
        }

        return nil  // Still evaluating
    }

    /// Update internal state to reflect a user's speaker correction.
    public func correctSpeaker(from fromLabel: String, to toLabel: String) {
        lock.withLock {
            if confirmedResult?.label == fromLabel {
                confirmedResult = SpeakerIdentification(label: toLabel, confidence: confirmedResult?.confidence ?? 1.0)
            } else if confirmedResult?.label == toLabel {
                confirmedResult = SpeakerIdentification(label: fromLabel, confidence: confirmedResult?.confidence ?? 1.0)
            }

            if pendingLabel == fromLabel {
                pendingLabel = toLabel
            } else if pendingLabel == toLabel {
                pendingLabel = fromLabel
            }
        }
    }

    public func reset() {
        lock.withLock {
            confirmedResult = nil
            pendingLabel = nil
            pendingCount = 0
        }
    }
}
