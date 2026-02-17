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

    public init(confirmationThreshold: Int = 2) {
        self.confirmationThreshold = max(1, confirmationThreshold)
    }

    /// Process a raw speaker identification from the diarizer.
    ///
    /// - Returns: The confirmed speaker identification (with confidence), or nil
    ///   if a potential speaker change is still being evaluated (pending).
    public func processLabel(_ identification: SpeakerIdentification?) -> SpeakerIdentification? {
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

    public func reset() {
        confirmedResult = nil
        pendingLabel = nil
        pendingCount = 0
    }
}
