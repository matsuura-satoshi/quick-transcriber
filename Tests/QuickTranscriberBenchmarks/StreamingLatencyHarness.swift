import Foundation
@testable import QuickTranscriberLib

public struct UtteranceBoundary: Sendable {
    public let utteranceId: String
    public let startSample: Int
    public let endSample: Int
}

public struct StreamingAudioStream: Sendable {
    public let samples: [Float]
    public let sampleRate: Int
    public let utteranceBoundaries: [UtteranceBoundary]
}

public struct LatencyBreakdown: Sendable {
    public let tVadWaitSeconds: Double
    public let tInferenceSeconds: Double
    public let tEmitSeconds: Double
    public let tTotalSeconds: Double
}

/// Concatenates utterance audio with synthetic silence gaps to simulate
/// streaming input, and decomposes `LatencyInstrumentation` records into
/// per-utterance stage breakdowns.
public struct StreamingLatencyHarness: Sendable {
    public let silenceGapSeconds: Double
    public let sampleRate: Int

    public init(silenceGapSeconds: Double, sampleRate: Int) {
        self.silenceGapSeconds = silenceGapSeconds
        self.sampleRate = sampleRate
    }

    /// Concatenate utterances with `silenceGapSeconds` of silence between
    /// each pair. No trailing silence on the last utterance.
    public func concatenate(utterances: [[Float]]) -> StreamingAudioStream {
        let gapSamples = Int(silenceGapSeconds * Double(sampleRate))
        var samples: [Float] = []
        var boundaries: [UtteranceBoundary] = []
        samples.reserveCapacity(
            utterances.reduce(0) { $0 + $1.count } + gapSamples * max(0, utterances.count - 1)
        )

        for (idx, utterance) in utterances.enumerated() {
            let start = samples.count
            samples.append(contentsOf: utterance)
            boundaries.append(
                UtteranceBoundary(
                    utteranceId: "u\(idx)",
                    startSample: start,
                    endSample: samples.count
                )
            )
            if idx != utterances.count - 1 {
                samples.append(contentsOf: [Float](repeating: 0.0, count: gapSamples))
            }
        }

        return StreamingAudioStream(
            samples: samples,
            sampleRate: sampleRate,
            utteranceBoundaries: boundaries
        )
    }

    /// Decompose latency records for a single utterance into its pipeline stages.
    /// Returns zeroed breakdown when no records are found for the id.
    public static func perUtteranceLatency(
        from records: [LatencyRecord],
        utteranceId: String
    ) -> LatencyBreakdown {
        let own = records.filter { $0.utteranceId == utteranceId }
        guard !own.isEmpty else {
            return LatencyBreakdown(
                tVadWaitSeconds: 0,
                tInferenceSeconds: 0,
                tEmitSeconds: 0,
                tTotalSeconds: 0
            )
        }

        func ts(_ stage: LatencyStage) -> UInt64? {
            own.first(where: { $0.stage == stage })?.timestampNanos
        }

        let vadOnset = ts(.vadOnset)
        let vadConfirm = ts(.vadConfirmSilence) ?? vadOnset ?? 0
        let infStart = ts(.inferenceStart) ?? vadConfirm
        let infEnd = ts(.inferenceEnd) ?? infStart
        let emit = ts(.emitToUI) ?? infEnd

        let tVadWait: Double
        if let onset = vadOnset {
            tVadWait = Double(vadConfirm &- onset) / 1e9
        } else {
            tVadWait = 0
        }
        let tInference = Double(infEnd &- infStart) / 1e9
        let tEmit = Double(emit &- infEnd) / 1e9
        let tTotal = Double(emit &- vadConfirm) / 1e9

        return LatencyBreakdown(
            tVadWaitSeconds: tVadWait,
            tInferenceSeconds: tInference,
            tEmitSeconds: tEmit,
            tTotalSeconds: tTotal
        )
    }
}
