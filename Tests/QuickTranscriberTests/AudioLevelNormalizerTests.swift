import XCTest
@testable import QuickTranscriberLib

final class AudioLevelNormalizerTests: XCTestCase {
    private let sampleRate: Double = 16000.0

    private func makeBuffer(amplitude: Float, duration: TimeInterval) -> [Float] {
        [Float](repeating: amplitude, count: Int(duration * sampleRate))
    }

    func testInitialGainIsOne() {
        let normalizer = AudioLevelNormalizer()
        XCTAssertEqual(normalizer.currentGain, 1.0)
    }

    func testQuietInputIsBoosted() {
        var normalizer = AudioLevelNormalizer()
        let quietBuffer = makeBuffer(amplitude: 0.005, duration: 0.1)
        var output: [Float] = []
        for _ in 0..<20 {
            output = normalizer.normalize(quietBuffer)
        }
        let outputPeak = output.map { abs($0) }.max() ?? 0
        XCTAssertGreaterThan(outputPeak, 0.005, "Quiet input should be boosted")
    }

    func testLoudInputNotAttenuated() {
        var normalizer = AudioLevelNormalizer()
        let loudBuffer = makeBuffer(amplitude: 0.6, duration: 0.1)
        var output: [Float] = []
        for _ in 0..<20 {
            output = normalizer.normalize(loudBuffer)
        }
        let outputPeak = output.map { abs($0) }.max() ?? 0
        XCTAssertGreaterThanOrEqual(outputPeak, 0.6, "Loud input should not be attenuated")
    }

    func testMaxGainIsRespected() {
        var normalizer = AudioLevelNormalizer()
        let veryQuietBuffer = makeBuffer(amplitude: 0.001, duration: 0.1)
        var output: [Float] = []
        for _ in 0..<50 {
            output = normalizer.normalize(veryQuietBuffer)
        }
        let outputPeak = output.map { abs($0) }.max() ?? 0
        XCTAssertLessThanOrEqual(outputPeak, 0.001 * Constants.AudioNormalization.maxGain + 0.001,
                                  "Output should respect max gain limit")
    }

    func testOutputIsClampedToUnitRange() {
        var normalizer = AudioLevelNormalizer()
        let buffer = makeBuffer(amplitude: 0.15, duration: 0.1)
        for _ in 0..<50 {
            let output = normalizer.normalize(buffer)
            let maxVal = output.map { abs($0) }.max() ?? 0
            XCTAssertLessThanOrEqual(maxVal, 1.0, "Output must be clamped to [-1.0, 1.0]")
        }
    }

    func testSilentInputReturnsZeros() {
        var normalizer = AudioLevelNormalizer()
        let silentBuffer = makeBuffer(amplitude: 0.0, duration: 0.1)
        let output = normalizer.normalize(silentBuffer)
        let maxVal = output.map { abs($0) }.max() ?? 0
        XCTAssertEqual(maxVal, 0.0, "Silent input should remain silent")
    }

    func testPeakDecaysOverTime() {
        var normalizer = AudioLevelNormalizer()
        let loudBuffer = makeBuffer(amplitude: 0.5, duration: 0.1)
        _ = normalizer.normalize(loudBuffer)
        let peakAfterLoud = normalizer.runningPeak

        let quietBuffer = makeBuffer(amplitude: 0.001, duration: 0.1)
        for _ in 0..<30 {
            _ = normalizer.normalize(quietBuffer)
        }
        let peakAfterDecay = normalizer.runningPeak

        XCTAssertLessThan(peakAfterDecay, peakAfterLoud, "Peak should decay over time")
    }
}
