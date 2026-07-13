import XCTest
import FluidAudio
@testable import QuickTranscriberLib

/// Separability diagnostic (2026-07-14 spec): measures how well the FluidAudio
/// embedding separates speakers when fed GT-pure single-speaker spans, across
/// acoustic conditions:
///   A. real-sessions (Zoom far-end + meeting room, ja)  — the problem condition
///   B. AMI            (meeting-room mics, en)
///   C. callhome_ja    (telephone, ja)
///   D. callhome_en    (telephone, en)
/// Each test writes /tmp/separability_<dataset>.json; LOO analysis lives in
/// docs/benchmarks/2026-07-14-separability/separability_analysis.py.
final class SeparabilityBenchmarkTests: DiarizationBenchmarkTestBase {

    struct SpanEmbedding: Codable {
        let speaker: String
        let start: Double
        let end: Double
        let embedding: [Float]
    }

    struct RecordingArtifact: Codable {
        let recording: String
        let spans: [SpanEmbedding]
    }

    struct SeparabilityArtifact: Codable {
        let dataset: String
        let recordings: [RecordingArtifact]
    }

    /// Cap per (recording, speaker): LOO needs breadth across speakers, not
    /// depth per speaker; caps keep AMI's 30-min meetings tractable.
    private static let maxSpansPerSpeaker = 30

    // MARK: - Span embedding extraction

    private func makeManager() async throws -> OfflineDiarizerManager {
        let manager = OfflineDiarizerManager(config: OfflineDiarizerConfig())
        try await manager.prepareModels()
        return manager
    }

    /// Embed one GT-pure span: run the offline diarizer on the span audio and
    /// take the duration-weighted mean embedding of the dominant internal
    /// cluster (the diarizer may split spuriously; dominance by total duration).
    private func embedSpan(
        manager: OfflineDiarizerManager,
        samples: ArraySlice<Float>
    ) async throws -> [Float]? {
        let result = try await manager.process(audio: Array(samples))
        var totals: [String: Float] = [:]
        for seg in result.segments {
            totals[seg.speakerId, default: 0] += seg.endTimeSeconds - seg.startTimeSeconds
        }
        guard let dominant = totals.max(by: { $0.value < $1.value })?.key else { return nil }
        let members = result.segments.filter { $0.speakerId == dominant }
        let weighted = members.map {
            (embedding: $0.embedding, weight: $0.endTimeSeconds - $0.startTimeSeconds)
        }
        return EmbeddingMath.weightedMean(weighted)
    }

    private func extractRecording(
        name: String,
        samples: [Float],
        gtSegments: [PureSpan],
        manager: OfflineDiarizerManager
    ) async throws -> RecordingArtifact {
        let sr = 16000
        let spans = PureSpanExtractor.extract(segments: gtSegments)

        var perSpeakerCount: [String: Int] = [:]
        var out: [SpanEmbedding] = []
        for span in spans {
            if perSpeakerCount[span.speaker, default: 0] >= Self.maxSpansPerSpeaker { continue }
            let startSample = max(0, Int(span.start * Double(sr)))
            let endSample = min(samples.count, Int(span.end * Double(sr)))
            guard endSample > startSample else { continue }
            guard let emb = try await embedSpan(
                manager: manager, samples: samples[startSample..<endSample]
            ) else { continue }
            perSpeakerCount[span.speaker, default: 0] += 1
            out.append(SpanEmbedding(
                speaker: span.speaker, start: span.start, end: span.end, embedding: emb
            ))
        }
        NSLog("[Separability] \(name): \(spans.count) pure spans -> \(out.count) embedded, per speaker \(perSpeakerCount)")
        return RecordingArtifact(recording: name, spans: out)
    }

    private func writeArtifact(_ artifact: SeparabilityArtifact) throws {
        let url = URL(fileURLWithPath: "/tmp/separability_\(artifact.dataset).json")
        try JSONEncoder().encode(artifact).write(to: url, options: .atomic)
        NSLog("[Separability] artifact written: \(url.path)")
    }

    // MARK: - Condition A: real sessions (Zoom far-end + meeting room, ja)

    func testSeparability_realSessions() async throws {
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: ConfusionPairAnalysisTests.sessionsRoot.path),
            "real-sessions directory not present"
        )
        let manager = try await makeManager()
        var recordings: [RecordingArtifact] = []

        for session in ConfusionPairAnalysisTests.sessions {
            let dir = ConfusionPairAnalysisTests.sessionsRoot.appendingPathComponent(session.dirName)
            let zoomURL = dir.appendingPathComponent("zoom_transcript.txt")
            guard FileManager.default.fileExists(atPath: zoomURL.path) else { continue }
            let zoomRaw = try String(contentsOf: zoomURL, encoding: .utf8)
            let gt = try SessionTimeAligner.zoomSegmentsAudioRelative(
                zoomRaw: zoomRaw,
                qtStartSecondsOfDay: session.qtStartSecondsOfDay,
                audioDurationSeconds: session.audioDurationSeconds
            )
            // Zoom GT has ±sub-second alignment error; the default 0.25s trim
            // plus subtraction of overlapping utterances is the protocol's
            // purity guard (see spec Limitations).
            let gtSpans = gt.compactMap { seg -> PureSpan? in
                guard let short = ConfusionPairAnalysisTests.zoomToShort[seg.speaker] else { return nil }
                return PureSpan(speaker: short, start: seg.startSeconds, end: seg.endSeconds)
            }
            let samples = try loadAudioSamples(from: dir.appendingPathComponent("audio.wav").path)
            recordings.append(try await extractRecording(
                name: session.dirName, samples: samples, gtSegments: gtSpans, manager: manager
            ))
        }

        XCTAssertFalse(recordings.isEmpty, "no real sessions processed")
        try writeArtifact(SeparabilityArtifact(dataset: "real_sessions", recordings: recordings))
    }

    // MARK: - Conditions B–D: references.json corpora

    private func runCorpus(dataset: String, maxRecordings: Int) async throws {
        let refs = try loadDiarizationReferences(name: dataset)
        let dir = datasetDir(name: dataset)
        let manager = try await makeManager()
        var recordings: [RecordingArtifact] = []

        for key in refs.keys.sorted().prefix(maxRecordings) {
            guard let ref = refs[key] else { continue }
            let wavPath = dir.appendingPathComponent("\(key).wav").path
            guard FileManager.default.fileExists(atPath: wavPath) else { continue }
            let gtSpans = ref.segments.map {
                PureSpan(speaker: $0.speaker, start: $0.start, end: $0.end)
            }
            let samples = try loadAudioSamples(from: wavPath)
            recordings.append(try await extractRecording(
                name: key, samples: samples, gtSegments: gtSpans, manager: manager
            ))
        }

        XCTAssertFalse(recordings.isEmpty, "no recordings processed for \(dataset)")
        try writeArtifact(SeparabilityArtifact(dataset: dataset, recordings: recordings))
    }

    func testSeparability_ami() async throws {
        try await runCorpus(dataset: "ami", maxRecordings: 8)
    }

    func testSeparability_callhome_ja() async throws {
        try await runCorpus(dataset: "callhome_ja", maxRecordings: 10)
    }

    func testSeparability_callhome_en() async throws {
        try await runCorpus(dataset: "callhome_en", maxRecordings: 10)
    }
}
