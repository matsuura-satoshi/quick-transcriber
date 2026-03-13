import Foundation

public struct AudioLevelNormalizer: Sendable {
    public private(set) var runningPeak: Float = 0.0
    public private(set) var currentGain: Float = 1.0

    private let targetPeak: Float
    private let minGain: Float
    private let maxGain: Float
    private let windowDuration: TimeInterval
    private let attackCoefficient: Float
    private let releaseCoefficient: Float
    private let sampleRate: Double

    public init(
        targetPeak: Float = Constants.AudioNormalization.targetPeak,
        minGain: Float = Constants.AudioNormalization.minGain,
        maxGain: Float = Constants.AudioNormalization.maxGain,
        windowDuration: TimeInterval = Constants.AudioNormalization.windowDuration,
        attackCoefficient: Float = Constants.AudioNormalization.attackCoefficient,
        releaseCoefficient: Float = Constants.AudioNormalization.releaseCoefficient,
        sampleRate: Double = Constants.Audio.sampleRate
    ) {
        self.targetPeak = targetPeak
        self.minGain = minGain
        self.maxGain = maxGain
        self.windowDuration = windowDuration
        self.attackCoefficient = attackCoefficient
        self.releaseCoefficient = releaseCoefficient
        self.sampleRate = sampleRate
    }

    public mutating func normalize(_ samples: [Float]) -> [Float] {
        guard !samples.isEmpty else { return samples }

        let bufferPeak = samples.reduce(Float(0)) { max($0, abs($1)) }
        let bufferDuration = TimeInterval(samples.count) / sampleRate
        if bufferPeak > runningPeak {
            runningPeak = bufferPeak
        } else {
            let decayFactor = Float(pow(0.01, bufferDuration / windowDuration))
            runningPeak = runningPeak * decayFactor
        }

        let rawGain: Float
        if runningPeak < 1e-6 {
            rawGain = 1.0
        } else {
            rawGain = min(max(targetPeak / runningPeak, minGain), maxGain)
        }

        if rawGain < currentGain {
            currentGain += (rawGain - currentGain) * attackCoefficient
        } else {
            currentGain += (rawGain - currentGain) * releaseCoefficient
        }

        return samples.map { sample in
            min(max(sample * currentGain, -1.0), 1.0)
        }
    }
}
