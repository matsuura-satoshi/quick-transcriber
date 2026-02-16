import Foundation

public struct DiarizationMetrics: Codable, Sendable {
    public let chunkAccuracy: Double
    public let speakerCountCorrect: Bool
    public let detectedSpeakerCount: Int
    public let actualSpeakerCount: Int
    public let labelFlips: Int

    public static func compute(
        groundTruth: [String],
        predicted: [String]
    ) -> DiarizationMetrics {
        precondition(groundTruth.count == predicted.count)
        let n = groundTruth.count
        guard n > 0 else {
            return DiarizationMetrics(
                chunkAccuracy: 1.0, speakerCountCorrect: true,
                detectedSpeakerCount: 0, actualSpeakerCount: 0, labelFlips: 0
            )
        }

        let gtLabels = Array(Set(groundTruth)).sorted()
        let predLabels = Array(Set(predicted)).sorted()

        let size = max(gtLabels.count, predLabels.count)
        var cost = Array(repeating: Array(repeating: 0, count: size), count: size)

        for i in 0..<n {
            if let gtIdx = gtLabels.firstIndex(of: groundTruth[i]),
               let predIdx = predLabels.firstIndex(of: predicted[i]) {
                cost[gtIdx][predIdx] -= 1
            }
        }

        let assignment = HungarianAlgorithm.solve(cost)

        var predToGt: [String: String] = [:]
        for (gtIdx, predIdx) in assignment.enumerated() {
            if gtIdx < gtLabels.count && predIdx < predLabels.count {
                predToGt[predLabels[predIdx]] = gtLabels[gtIdx]
            }
        }

        var correct = 0
        for i in 0..<n {
            if predToGt[predicted[i]] == groundTruth[i] {
                correct += 1
            }
        }

        var flips = 0
        for i in 1..<n {
            if predicted[i] != predicted[i - 1] {
                flips += 1
            }
        }

        return DiarizationMetrics(
            chunkAccuracy: Double(correct) / Double(n),
            speakerCountCorrect: gtLabels.count == predLabels.count,
            detectedSpeakerCount: predLabels.count,
            actualSpeakerCount: gtLabels.count,
            labelFlips: flips
        )
    }
}
