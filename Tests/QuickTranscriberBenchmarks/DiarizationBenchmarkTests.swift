import XCTest
import AVFoundation
@testable import QuickTranscriberLib

/// Reference format for CALLHOME diarization datasets.
struct DiarizationReference: Codable {
    let language: String
    let duration_seconds: Double
    let speakers: Int
    let segments: [SegmentRef]

    struct SegmentRef: Codable {
        let start: Double
        let end: Double
        let speaker: String
    }
}

/// Aggregated results across multiple conversations.
struct DiarizationBenchmarkResult: Codable {
    let dataset: String
    let label: String
    let conversationCount: Int
    let averageChunkAccuracy: Double
    let averageLabelFlips: Double
    let speakerCountAccuracy: Double
}

/// Base class for diarization benchmark tests.
/// Simulates streaming: splits audio into fixed-length chunks,
/// feeds them to FluidAudioSpeakerDiarizer, and compares output
/// labels against ground truth using Hungarian algorithm.
class DiarizationBenchmarkTestBase: XCTestCase {

    var outputPath: String { "/tmp/quicktranscriber_diarization_results.json" }

    func datasetDir(name: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/QuickTranscriber/test-audio/\(name)")
    }

    func loadDiarizationReferences(name: String) throws -> [String: DiarizationReference] {
        let dir = datasetDir(name: name)
        let refsURL = dir.appendingPathComponent("references.json")
        guard FileManager.default.fileExists(atPath: refsURL.path) else {
            throw XCTSkip("Dataset \(name) not found. Run: python3 Scripts/download_datasets.py \(name)")
        }
        let data = try Data(contentsOf: refsURL)
        return try JSONDecoder().decode([String: DiarizationReference].self, from: data)
    }

    /// Load audio samples from a WAV file as a Float array at 16kHz mono.
    func loadAudioSamples(from path: String) throws -> [Float] {
        let audioURL = URL(fileURLWithPath: path)
        let audioFile = try AVAudioFile(forReading: audioURL)
        let sampleRate: Double = 16000
        let frameCount = AVAudioFrameCount(audioFile.length)
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw NSError(domain: "DiarizationBenchmark", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create audio format"])
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw NSError(domain: "DiarizationBenchmark", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create audio buffer"])
        }
        try audioFile.read(into: buffer)
        return Array(UnsafeBufferPointer(
            start: buffer.floatChannelData![0],
            count: Int(buffer.frameLength)
        ))
    }

    /// Determine ground-truth speaker label for a chunk by finding the speaker with most overlap.
    func groundTruthLabel(
        for chunkStart: Double,
        chunkEnd: Double,
        segments: [DiarizationReference.SegmentRef]
    ) -> String? {
        var speakerOverlap: [String: Double] = [:]
        for seg in segments {
            let overlapStart = max(seg.start, chunkStart)
            let overlapEnd = min(seg.end, chunkEnd)
            let overlap = max(0, overlapEnd - overlapStart)
            if overlap > 0 {
                speakerOverlap[seg.speaker, default: 0] += overlap
            }
        }
        return speakerOverlap.max(by: { $0.value < $1.value })?.key
    }

    /// Run diarization benchmark on a dataset.
    func runDiarizationBenchmark(
        dataset: String,
        maxConversations: Int = 50,
        chunkDuration: Double = 3.0,
        similarityThreshold: Float = 0.5,
        updateAlpha: Float = 0.3,
        windowDuration: TimeInterval = 30.0,
        label: String = "default"
    ) async throws -> DiarizationBenchmarkResult {
        let refs = try loadDiarizationReferences(name: dataset)
        let dir = datasetDir(name: dataset)
        let sampleRate = 16000

        let keys = Array(refs.keys.sorted().prefix(maxConversations))
        guard !keys.isEmpty else {
            throw XCTSkip("No conversations in dataset \(dataset)")
        }

        var allMetrics: [DiarizationMetrics] = []

        for key in keys {
            guard let ref = refs[key] else { continue }
            let wavPath = dir.appendingPathComponent("\(key).wav").path
            guard FileManager.default.fileExists(atPath: wavPath) else { continue }

            let samples = try loadAudioSamples(from: wavPath)

            // Create fresh diarizer for each conversation
            let diarizer = FluidAudioSpeakerDiarizer(
                similarityThreshold: similarityThreshold,
                updateAlpha: updateAlpha,
                windowDuration: windowDuration
            )
            try await diarizer.setup()

            // Split into chunks and feed to diarizer
            let chunkSamples = Int(chunkDuration * Double(sampleRate))
            var predictedLabels: [String] = []
            var groundTruthLabels: [String] = []

            var offset = 0
            while offset < samples.count {
                let end = min(offset + chunkSamples, samples.count)
                let chunk = Array(samples[offset..<end])
                let chunkStartTime = Double(offset) / Double(sampleRate)
                let chunkEndTime = Double(end) / Double(sampleRate)

                // Ground truth
                if let gtLabel = groundTruthLabel(
                    for: chunkStartTime,
                    chunkEnd: chunkEndTime,
                    segments: ref.segments
                ) {
                    groundTruthLabels.append(gtLabel)

                    // Prediction
                    let speakerLabel = await diarizer.identifySpeaker(audioChunk: chunk)
                    predictedLabels.append(speakerLabel ?? "__nil__")
                }
                // Skip chunks with no ground-truth speaker (silence/unannotated)

                offset = end
            }

            guard !groundTruthLabels.isEmpty else { continue }

            let metrics = DiarizationMetrics.compute(
                groundTruth: groundTruthLabels,
                predicted: predictedLabels
            )
            allMetrics.append(metrics)

            NSLog("[Diarization] \(key): accuracy=\(String(format: "%.2f", metrics.chunkAccuracy)) speakers=\(metrics.detectedSpeakerCount)/\(metrics.actualSpeakerCount) flips=\(metrics.labelFlips)")
        }

        guard !allMetrics.isEmpty else {
            throw XCTSkip("No conversations could be processed in \(dataset)")
        }

        // Aggregate
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

        NSLog("[Diarization] \(dataset)/\(label) | conversations=\(result.conversationCount) | avgAccuracy=\(String(format: "%.3f", avgAccuracy)) | avgFlips=\(String(format: "%.1f", avgFlips)) | speakerCountAcc=\(String(format: "%.2f", speakerCountAcc))")

        appendDiarizationResult(result)

        return result
    }

    private func appendDiarizationResult(_ result: DiarizationBenchmarkResult) {
        let url = URL(fileURLWithPath: outputPath)
        var existing: [DiarizationBenchmarkResult] = []
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([DiarizationBenchmarkResult].self, from: data) {
            existing = decoded
        }
        existing.append(result)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(existing) {
            try? data.write(to: url)
        }
    }
}

// MARK: - CALLHOME Diarization Benchmarks

final class CallHomeDiarizationTests: DiarizationBenchmarkTestBase {

    override var outputPath: String { "/tmp/quicktranscriber_diarization_results.json" }

    // MARK: - Smoke test (1 conversation, quick validation)

    func testCallHome_en_smoke() async throws {
        let result = try await runDiarizationBenchmark(
            dataset: "callhome_en", maxConversations: 1, label: "smoke"
        )
        XCTAssertGreaterThan(result.averageChunkAccuracy, 0.0)
    }

    // MARK: - Default parameters

    func testCallHome_en_default() async throws {
        let result = try await runDiarizationBenchmark(
            dataset: "callhome_en", maxConversations: 5, label: "default"
        )
        XCTAssertGreaterThan(result.averageChunkAccuracy, 0.0)
    }

    func testCallHome_ja_default() async throws {
        let result = try await runDiarizationBenchmark(
            dataset: "callhome_ja", maxConversations: 5, label: "default"
        )
        XCTAssertGreaterThan(result.averageChunkAccuracy, 0.0)
    }

    // MARK: - similarityThreshold variations

    func testCallHome_en_similarity03() async throws {
        let _ = try await runDiarizationBenchmark(
            dataset: "callhome_en", maxConversations: 5,
            similarityThreshold: 0.3, label: "similarity_0.3"
        )
    }

    func testCallHome_en_similarity04() async throws {
        let _ = try await runDiarizationBenchmark(
            dataset: "callhome_en", maxConversations: 5,
            similarityThreshold: 0.4, label: "similarity_0.4"
        )
    }

    func testCallHome_en_similarity06() async throws {
        let _ = try await runDiarizationBenchmark(
            dataset: "callhome_en", maxConversations: 5,
            similarityThreshold: 0.6, label: "similarity_0.6"
        )
    }

    func testCallHome_en_similarity07() async throws {
        let _ = try await runDiarizationBenchmark(
            dataset: "callhome_en", maxConversations: 5,
            similarityThreshold: 0.7, label: "similarity_0.7"
        )
    }

    func testCallHome_ja_similarity03() async throws {
        let _ = try await runDiarizationBenchmark(
            dataset: "callhome_ja", maxConversations: 5,
            similarityThreshold: 0.3, label: "similarity_0.3"
        )
    }

    func testCallHome_ja_similarity04() async throws {
        let _ = try await runDiarizationBenchmark(
            dataset: "callhome_ja", maxConversations: 5,
            similarityThreshold: 0.4, label: "similarity_0.4"
        )
    }

    func testCallHome_ja_similarity06() async throws {
        let _ = try await runDiarizationBenchmark(
            dataset: "callhome_ja", maxConversations: 5,
            similarityThreshold: 0.6, label: "similarity_0.6"
        )
    }

    func testCallHome_ja_similarity07() async throws {
        let _ = try await runDiarizationBenchmark(
            dataset: "callhome_ja", maxConversations: 5,
            similarityThreshold: 0.7, label: "similarity_0.7"
        )
    }

    // MARK: - chunkDuration variations

    func testCallHome_en_chunk5s() async throws {
        let _ = try await runDiarizationBenchmark(
            dataset: "callhome_en", maxConversations: 5,
            chunkDuration: 5.0, label: "chunk_5s"
        )
    }

    func testCallHome_en_chunk7s() async throws {
        let _ = try await runDiarizationBenchmark(
            dataset: "callhome_en", maxConversations: 5,
            chunkDuration: 7.0, label: "chunk_7s"
        )
    }

    func testCallHome_ja_chunk5s() async throws {
        let _ = try await runDiarizationBenchmark(
            dataset: "callhome_ja", maxConversations: 5,
            chunkDuration: 5.0, label: "chunk_5s"
        )
    }

    func testCallHome_ja_chunk7s() async throws {
        let _ = try await runDiarizationBenchmark(
            dataset: "callhome_ja", maxConversations: 5,
            chunkDuration: 7.0, label: "chunk_7s"
        )
    }

    // MARK: - windowDuration variations

    func testCallHome_en_window15s() async throws {
        let _ = try await runDiarizationBenchmark(
            dataset: "callhome_en", maxConversations: 5,
            windowDuration: 15.0, label: "window_15s"
        )
    }

    func testCallHome_en_window45s() async throws {
        let _ = try await runDiarizationBenchmark(
            dataset: "callhome_en", maxConversations: 5,
            windowDuration: 45.0, label: "window_45s"
        )
    }

    func testCallHome_en_window60s() async throws {
        let _ = try await runDiarizationBenchmark(
            dataset: "callhome_en", maxConversations: 5,
            windowDuration: 60.0, label: "window_60s"
        )
    }
}
