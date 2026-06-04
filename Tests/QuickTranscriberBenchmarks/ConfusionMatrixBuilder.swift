import Foundation

/// Confusion matrix over speaker labels: rows = ground-truth speaker,
/// columns = predicted speaker. Plus false-target attribution for the
/// silent-but-registered "magnet" speaker (e.g. 神野).
public struct ConfusionMatrixResult: Codable, Sendable {
    public let speakers: [String]
    /// counts[gt][pred]
    public let counts: [String: [String: Int]]
    public let falseTarget: String
    public let totalFalseTarget: Int
    public let falseTargetByGroundTruth: [String: Int]

    public func count(gt: String, pred: String) -> Int {
        counts[gt]?[pred] ?? 0
    }
    public func rowTotal(gt: String) -> Int {
        (counts[gt] ?? [:]).values.reduce(0, +)
    }
    public func accuracy(gt: String) -> Double {
        let total = rowTotal(gt: gt)
        guard total > 0 else { return 0 }
        return Double(count(gt: gt, pred: gt)) / Double(total)
    }
}

public enum ConfusionMatrixBuilder {
    /// - Parameters:
    ///   - rows: (groundTruth, predicted) label pairs, one per attributed chunk.
    ///   - speakers: full ordered label set for matrix dimensions.
    ///   - falseTarget: the silent magnet label to attribute (e.g. "神野").
    ///   - silentSpeakers: labels that never legitimately speak; any prediction
    ///     of `falseTarget` is a false assignment by construction.
    public static func build(
        rows: [(gt: String, pred: String)],
        speakers: [String],
        falseTarget: String,
        silentSpeakers: [String]
    ) -> ConfusionMatrixResult {
        var counts: [String: [String: Int]] = [:]
        for s in speakers { counts[s] = Dictionary(uniqueKeysWithValues: speakers.map { ($0, 0) }) }

        var falseByGt: [String: Int] = [:]
        var totalFalse = 0
        for row in rows {
            // Ensure both labels exist as keys even if outside `speakers`.
            counts[row.gt, default: [:]][row.pred, default: 0] += 1
            if row.pred == falseTarget && silentSpeakers.contains(falseTarget) {
                falseByGt[row.gt, default: 0] += 1
                totalFalse += 1
            }
        }
        return ConfusionMatrixResult(
            speakers: speakers,
            counts: counts,
            falseTarget: falseTarget,
            totalFalseTarget: totalFalse,
            falseTargetByGroundTruth: falseByGt
        )
    }
}
