import XCTest
import AVFoundation
@testable import QuickTranscriberLib

/// Compares diarization accuracy between VAD-driven chunking and fixed-duration chunking.
/// Uses the same diarizer pipeline but with different audio segmentation strategies.
final class ChunkedDiarizationTests: DiarizationBenchmarkTestBase {

    override var outputPath: String { "/tmp/quicktranscriber_chunked_diarization_results.json" }

    private let sampleRate = 16000

    enum DiarizationChunkingMode {
        case fixed(chunkDuration: Double)
        case vad
    }

    /// Run diarization benchmark with configurable chunking mode.
    /// For VAD mode, audio is fed in 100ms streaming increments through VADChunkAccumulator.
    /// For Fixed mode, audio is split into equal-size chunks (same as existing benchmarks).
    private func runChunkedDiarizationBenchmark(
        dataset: String,
        maxConversations: Int = 5,
        chunkingMode: DiarizationChunkingMode,
        similarityThreshold: Float = 0.5,
        windowDuration: TimeInterval = 15.0,
        diarizationChunkDuration: Double = 7.0,
        expectedSpeakerCount: Int? = nil,
        stayProbability: Double = 0.80,
        label: String
    ) async throws -> DiarizationBenchmarkResult {
        let refs = try loadDiarizationReferences(name: dataset)
        let dir = datasetDir(name: dataset)

        let keys = Array(refs.keys.sorted().prefix(maxConversations))
        guard !keys.isEmpty else {
            throw XCTSkip("No conversations in dataset \(dataset)")
        }

        var allMetrics: [DiarizationMetrics] = []

        for key in keys {
            guard let ref = refs[key] else { continue }
            let wavPath = dir.appendingPathComponent("\(key).wav").path
            guard FileManager.default.fileExists(atPath: wavPath) else { continue }

            let rawSamples = try loadAudioSamples(from: wavPath)
            // Normalize to simulate real microphone levels (dataset recordings are very quiet)
            let samples = ChunkedTranscriptionBenchmarkRunner.normalizeAudio(rawSamples, targetPeak: 0.5)

            let effectiveExpectedCount: Int? = if expectedSpeakerCount == -1 {
                ref.speakers
            } else {
                expectedSpeakerCount
            }

            let diarizer = FluidAudioSpeakerDiarizer(
                similarityThreshold: similarityThreshold,
                windowDuration: windowDuration,
                diarizationChunkDuration: diarizationChunkDuration,
                expectedSpeakerCount: effectiveExpectedCount
            )
            try await diarizer.setup()

            let smoother = ViterbiSpeakerSmoother(stayProbability: stayProbability)
            var pendingStartIndex: Int?
            var predictedLabels: [String] = []
            var groundTruthLabels: [String] = []

            // Generate chunks based on mode
            let audioChunks: [(samples: [Float], startTime: Double, endTime: Double)]

            switch chunkingMode {
            case .fixed(let chunkDuration):
                audioChunks = generateFixedChunks(
                    samples: samples, chunkDuration: chunkDuration
                )
            case .vad:
                audioChunks = generateVADChunks(samples: samples)
            }

            // Feed chunks to diarizer
            for chunk in audioChunks {
                guard let gtLabel = groundTruthLabel(
                    for: chunk.startTime,
                    chunkEnd: chunk.endTime,
                    segments: ref.segments
                ) else { continue }

                let rawResult = await diarizer.identifySpeaker(audioChunk: chunk.samples)
                guard let rawResult else { continue }

                let smoothed = smoother.process(rawResult)
                if let smoothed {
                    if let startIdx = pendingStartIndex {
                        for i in startIdx..<predictedLabels.count {
                            predictedLabels[i] = smoothed.speakerId.uuidString
                        }
                        pendingStartIndex = nil
                    }
                    groundTruthLabels.append(gtLabel)
                    predictedLabels.append(smoothed.speakerId.uuidString)
                } else {
                    if pendingStartIndex == nil {
                        pendingStartIndex = predictedLabels.count
                    }
                    groundTruthLabels.append(gtLabel)
                    predictedLabels.append("__pending__")
                }
            }

            // Fill remaining pending labels
            if let startIdx = pendingStartIndex {
                let lastConfirmed = predictedLabels[0..<startIdx].last { $0 != "__pending__" }
                if let label = lastConfirmed {
                    for i in startIdx..<predictedLabels.count {
                        if predictedLabels[i] == "__pending__" {
                            predictedLabels[i] = label
                        }
                    }
                }
            }

            guard !groundTruthLabels.isEmpty else { continue }

            let metrics = DiarizationMetrics.compute(
                groundTruth: groundTruthLabels,
                predicted: predictedLabels
            )
            allMetrics.append(metrics)

            NSLog("[ChunkedDiar] \(key)/\(label): accuracy=\(String(format: "%.2f", metrics.chunkAccuracy)) speakers=\(metrics.detectedSpeakerCount)/\(metrics.actualSpeakerCount) flips=\(metrics.labelFlips) chunks=\(audioChunks.count)")
        }

        guard !allMetrics.isEmpty else {
            throw XCTSkip("No conversations processed in \(dataset)")
        }

        let avgAccuracy = allMetrics.map(\.chunkAccuracy).reduce(0, +) / Double(allMetrics.count)
        let avgFlips = Double(allMetrics.map(\.labelFlips).reduce(0, +)) / Double(allMetrics.count)
        let speakerCountAcc = Double(allMetrics.filter(\.speakerCountCorrect).count) / Double(allMetrics.count)

        let result = DiarizationBenchmarkResult(
            dataset: dataset,
            label: label,
            conversationCount: allMetrics.count,
            averageChunkAccuracy: avgAccuracy,
            averageLabelFlips: avgFlips,
            speakerCountAccuracy: speakerCountAcc
        )

        NSLog("[ChunkedDiar] \(dataset)/\(label) | conversations=\(result.conversationCount) | avgAccuracy=\(String(format: "%.3f", avgAccuracy)) | avgFlips=\(String(format: "%.1f", avgFlips))")

        return result
    }

    // MARK: - Chunk Generation

    private func generateFixedChunks(
        samples: [Float],
        chunkDuration: Double
    ) -> [(samples: [Float], startTime: Double, endTime: Double)] {
        let chunkSamples = Int(chunkDuration * Double(sampleRate))
        var chunks: [(samples: [Float], startTime: Double, endTime: Double)] = []
        var offset = 0
        while offset < samples.count {
            let end = Swift.min(offset + chunkSamples, samples.count)
            let chunk = Array(samples[offset..<end])
            let startTime = Double(offset) / Double(sampleRate)
            let endTime = Double(end) / Double(sampleRate)
            chunks.append((samples: chunk, startTime: startTime, endTime: endTime))
            offset = end
        }
        return chunks
    }

    private func generateVADChunks(
        samples: [Float]
    ) -> [(samples: [Float], startTime: Double, endTime: Double)] {
        var acc = VADChunkAccumulator()
        let incrementSize = Int(0.1 * Double(sampleRate)) // 100ms
        var chunks: [(samples: [Float], startTime: Double, endTime: Double)] = []
        var sampleOffset = 0
        var chunkStartSample = 0

        var offset = 0
        while offset < samples.count {
            let end = Swift.min(offset + incrementSize, samples.count)
            let slice = Array(samples[offset..<end])
            sampleOffset = end

            if let result = acc.appendBuffer(slice) {
                let endTime = Double(sampleOffset) / Double(sampleRate)
                let startTime = endTime - Double(result.samples.count) / Double(sampleRate)
                chunks.append((samples: result.samples, startTime: startTime, endTime: endTime))
            }
            offset = end
        }

        // Flush remaining
        if let result = acc.flush() {
            let endTime = Double(sampleOffset) / Double(sampleRate)
            let startTime = endTime - Double(result.samples.count) / Double(sampleRate)
            chunks.append((samples: result.samples, startTime: startTime, endTime: endTime))
        }

        return chunks
    }

    // MARK: - CALLHOME English

    func testCallHome_en_fixed() async throws {
        let result = try await runChunkedDiarizationBenchmark(
            dataset: "callhome_en",
            maxConversations: 5,
            chunkingMode: .fixed(chunkDuration: 5.0),
            expectedSpeakerCount: 2,
            label: "fixed_5s"
        )
        NSLog("[ChunkedDiar] CALLHOME EN Fixed: accuracy=\(String(format: "%.3f", result.averageChunkAccuracy)) flips=\(String(format: "%.1f", result.averageLabelFlips))")
    }

    func testCallHome_en_vad() async throws {
        let result = try await runChunkedDiarizationBenchmark(
            dataset: "callhome_en",
            maxConversations: 5,
            chunkingMode: .vad,
            expectedSpeakerCount: 2,
            label: "vad"
        )
        NSLog("[ChunkedDiar] CALLHOME EN VAD: accuracy=\(String(format: "%.3f", result.averageChunkAccuracy)) flips=\(String(format: "%.1f", result.averageLabelFlips))")
    }

    // MARK: - CALLHOME Japanese

    func testCallHome_ja_fixed() async throws {
        let result = try await runChunkedDiarizationBenchmark(
            dataset: "callhome_ja",
            maxConversations: 5,
            chunkingMode: .fixed(chunkDuration: 5.0),
            expectedSpeakerCount: 2,
            label: "fixed_5s"
        )
        NSLog("[ChunkedDiar] CALLHOME JA Fixed: accuracy=\(String(format: "%.3f", result.averageChunkAccuracy)) flips=\(String(format: "%.1f", result.averageLabelFlips))")
    }

    func testCallHome_ja_vad() async throws {
        let result = try await runChunkedDiarizationBenchmark(
            dataset: "callhome_ja",
            maxConversations: 5,
            chunkingMode: .vad,
            expectedSpeakerCount: 2,
            label: "vad"
        )
        NSLog("[ChunkedDiar] CALLHOME JA VAD: accuracy=\(String(format: "%.3f", result.averageChunkAccuracy)) flips=\(String(format: "%.1f", result.averageLabelFlips))")
    }

    // MARK: - AMI Meeting Corpus

    func testAMI_fixed() async throws {
        let result = try await runChunkedDiarizationBenchmark(
            dataset: "ami",
            maxConversations: 5,
            chunkingMode: .fixed(chunkDuration: 5.0),
            expectedSpeakerCount: -1,
            label: "fixed_5s"
        )
        NSLog("[ChunkedDiar] AMI Fixed: accuracy=\(String(format: "%.3f", result.averageChunkAccuracy)) flips=\(String(format: "%.1f", result.averageLabelFlips))")
    }

    func testAMI_vad() async throws {
        let result = try await runChunkedDiarizationBenchmark(
            dataset: "ami",
            maxConversations: 5,
            chunkingMode: .vad,
            expectedSpeakerCount: -1,
            label: "vad"
        )
        NSLog("[ChunkedDiar] AMI VAD: accuracy=\(String(format: "%.3f", result.averageChunkAccuracy)) flips=\(String(format: "%.1f", result.averageLabelFlips))")
    }
}
