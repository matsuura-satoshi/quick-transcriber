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
    private var confirmedSpeaker: String?
    private var pendingLabel: String?
    private var pendingCount: Int = 0

    public init(confirmationThreshold: Int = 2) {
        self.confirmationThreshold = max(1, confirmationThreshold)
    }

    /// Process a raw speaker label from the diarizer.
    ///
    /// - Returns: The confirmed speaker label, or nil if a potential speaker
    ///   change is still being evaluated (pending).
    public func processLabel(_ rawLabel: String?) -> String? {
        guard let label = rawLabel else {
            return confirmedSpeaker
        }

        // First speaker: confirm immediately
        if confirmedSpeaker == nil {
            confirmedSpeaker = label
            pendingLabel = nil
            pendingCount = 0
            return label
        }

        // Same as confirmed: reset pending state
        if label == confirmedSpeaker {
            pendingLabel = nil
            pendingCount = 0
            return label
        }

        // Different from confirmed: evaluate
        if label == pendingLabel {
            pendingCount += 1
        } else {
            pendingLabel = label
            pendingCount = 1
        }

        if pendingCount >= confirmationThreshold {
            confirmedSpeaker = label
            pendingLabel = nil
            pendingCount = 0
            return label
        }

        return nil  // Still evaluating
    }

    public func reset() {
        confirmedSpeaker = nil
        pendingLabel = nil
        pendingCount = 0
    }
}
