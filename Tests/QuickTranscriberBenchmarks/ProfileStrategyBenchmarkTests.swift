import XCTest
@testable import QuickTranscriberLib

final class ProfileStrategyBenchmarkTests: DiarizationBenchmarkTestBase {

    override var outputPath: String { "/tmp/quicktranscriber_profile_strategy_results.json" }

    private let chunk: Double = 5.0
    private let window: TimeInterval = 15.0
    private let accum: Double = 7.0

    // MARK: - Baseline (no strategy)

    func testBaseline_callhome_en() async throws {
        let _ = try await runDiarizationBenchmark(
            dataset: "callhome_en", maxConversations: 5,
            chunkDuration: chunk, windowDuration: window,
            diarizationChunkDuration: accum,
            expectedSpeakerCount: 2,
            label: "baseline_en"
        )
    }

    func testBaseline_callhome_ja() async throws {
        let _ = try await runDiarizationBenchmark(
            dataset: "callhome_ja", maxConversations: 5,
            chunkDuration: chunk, windowDuration: window,
            diarizationChunkDuration: accum,
            expectedSpeakerCount: 2,
            label: "baseline_ja"
        )
    }

    func testBaseline_ami() async throws {
        let _ = try await runDiarizationBenchmark(
            dataset: "ami", maxConversations: 5,
            chunkDuration: chunk, windowDuration: window,
            diarizationChunkDuration: accum,
            expectedSpeakerCount: -1,
            label: "baseline_ami"
        )
    }

    // MARK: - Culling (interval=10, minHits=2)

    func testCull10_2_callhome_en() async throws {
        let _ = try await runDiarizationBenchmark(
            dataset: "callhome_en", maxConversations: 5,
            chunkDuration: chunk, windowDuration: window,
            diarizationChunkDuration: accum,
            expectedSpeakerCount: 2,
            profileStrategy: .culling(interval: 10, minHits: 2),
            label: "cull_10_2_en"
        )
    }

    func testCull10_2_callhome_ja() async throws {
        let _ = try await runDiarizationBenchmark(
            dataset: "callhome_ja", maxConversations: 5,
            chunkDuration: chunk, windowDuration: window,
            diarizationChunkDuration: accum,
            expectedSpeakerCount: 2,
            profileStrategy: .culling(interval: 10, minHits: 2),
            label: "cull_10_2_ja"
        )
    }

    func testCull10_2_ami() async throws {
        let _ = try await runDiarizationBenchmark(
            dataset: "ami", maxConversations: 5,
            chunkDuration: chunk, windowDuration: window,
            diarizationChunkDuration: accum,
            expectedSpeakerCount: -1,
            profileStrategy: .culling(interval: 10, minHits: 2),
            label: "cull_10_2_ami"
        )
    }

    // MARK: - Culling (interval=5, minHits=1)

    func testCull5_1_callhome_en() async throws {
        let _ = try await runDiarizationBenchmark(
            dataset: "callhome_en", maxConversations: 5,
            chunkDuration: chunk, windowDuration: window,
            diarizationChunkDuration: accum,
            expectedSpeakerCount: 2,
            profileStrategy: .culling(interval: 5, minHits: 1),
            label: "cull_5_1_en"
        )
    }

    func testCull5_1_callhome_ja() async throws {
        let _ = try await runDiarizationBenchmark(
            dataset: "callhome_ja", maxConversations: 5,
            chunkDuration: chunk, windowDuration: window,
            diarizationChunkDuration: accum,
            expectedSpeakerCount: 2,
            profileStrategy: .culling(interval: 5, minHits: 1),
            label: "cull_5_1_ja"
        )
    }

    func testCull5_1_ami() async throws {
        let _ = try await runDiarizationBenchmark(
            dataset: "ami", maxConversations: 5,
            chunkDuration: chunk, windowDuration: window,
            diarizationChunkDuration: accum,
            expectedSpeakerCount: -1,
            profileStrategy: .culling(interval: 5, minHits: 1),
            label: "cull_5_1_ami"
        )
    }

    // MARK: - Merging (interval=10, threshold=0.6)

    func testMerge10_06_callhome_en() async throws {
        let _ = try await runDiarizationBenchmark(
            dataset: "callhome_en", maxConversations: 5,
            chunkDuration: chunk, windowDuration: window,
            diarizationChunkDuration: accum,
            expectedSpeakerCount: 2,
            profileStrategy: .merging(interval: 10, threshold: 0.6),
            label: "merge_10_06_en"
        )
    }

    func testMerge10_06_callhome_ja() async throws {
        let _ = try await runDiarizationBenchmark(
            dataset: "callhome_ja", maxConversations: 5,
            chunkDuration: chunk, windowDuration: window,
            diarizationChunkDuration: accum,
            expectedSpeakerCount: 2,
            profileStrategy: .merging(interval: 10, threshold: 0.6),
            label: "merge_10_06_ja"
        )
    }

    func testMerge10_06_ami() async throws {
        let _ = try await runDiarizationBenchmark(
            dataset: "ami", maxConversations: 5,
            chunkDuration: chunk, windowDuration: window,
            diarizationChunkDuration: accum,
            expectedSpeakerCount: -1,
            profileStrategy: .merging(interval: 10, threshold: 0.6),
            label: "merge_10_06_ami"
        )
    }

    // MARK: - Merging (interval=10, threshold=0.7)

    func testMerge10_07_callhome_en() async throws {
        let _ = try await runDiarizationBenchmark(
            dataset: "callhome_en", maxConversations: 5,
            chunkDuration: chunk, windowDuration: window,
            diarizationChunkDuration: accum,
            expectedSpeakerCount: 2,
            profileStrategy: .merging(interval: 10, threshold: 0.7),
            label: "merge_10_07_en"
        )
    }

    func testMerge10_07_callhome_ja() async throws {
        let _ = try await runDiarizationBenchmark(
            dataset: "callhome_ja", maxConversations: 5,
            chunkDuration: chunk, windowDuration: window,
            diarizationChunkDuration: accum,
            expectedSpeakerCount: 2,
            profileStrategy: .merging(interval: 10, threshold: 0.7),
            label: "merge_10_07_ja"
        )
    }

    func testMerge10_07_ami() async throws {
        let _ = try await runDiarizationBenchmark(
            dataset: "ami", maxConversations: 5,
            chunkDuration: chunk, windowDuration: window,
            diarizationChunkDuration: accum,
            expectedSpeakerCount: -1,
            profileStrategy: .merging(interval: 10, threshold: 0.7),
            label: "merge_10_07_ami"
        )
    }

    // MARK: - Registration Gate (minSeparation=0.3)

    func testGate03_callhome_en() async throws {
        let _ = try await runDiarizationBenchmark(
            dataset: "callhome_en", maxConversations: 5,
            chunkDuration: chunk, windowDuration: window,
            diarizationChunkDuration: accum,
            expectedSpeakerCount: 2,
            profileStrategy: .registrationGate(minSeparation: 0.3),
            label: "gate_03_en"
        )
    }

    func testGate03_callhome_ja() async throws {
        let _ = try await runDiarizationBenchmark(
            dataset: "callhome_ja", maxConversations: 5,
            chunkDuration: chunk, windowDuration: window,
            diarizationChunkDuration: accum,
            expectedSpeakerCount: 2,
            profileStrategy: .registrationGate(minSeparation: 0.3),
            label: "gate_03_ja"
        )
    }

    func testGate03_ami() async throws {
        let _ = try await runDiarizationBenchmark(
            dataset: "ami", maxConversations: 5,
            chunkDuration: chunk, windowDuration: window,
            diarizationChunkDuration: accum,
            expectedSpeakerCount: -1,
            profileStrategy: .registrationGate(minSeparation: 0.3),
            label: "gate_03_ami"
        )
    }

    // MARK: - Registration Gate (minSeparation=0.4)

    func testGate04_callhome_en() async throws {
        let _ = try await runDiarizationBenchmark(
            dataset: "callhome_en", maxConversations: 5,
            chunkDuration: chunk, windowDuration: window,
            diarizationChunkDuration: accum,
            expectedSpeakerCount: 2,
            profileStrategy: .registrationGate(minSeparation: 0.4),
            label: "gate_04_en"
        )
    }

    func testGate04_callhome_ja() async throws {
        let _ = try await runDiarizationBenchmark(
            dataset: "callhome_ja", maxConversations: 5,
            chunkDuration: chunk, windowDuration: window,
            diarizationChunkDuration: accum,
            expectedSpeakerCount: 2,
            profileStrategy: .registrationGate(minSeparation: 0.4),
            label: "gate_04_ja"
        )
    }

    func testGate04_ami() async throws {
        let _ = try await runDiarizationBenchmark(
            dataset: "ami", maxConversations: 5,
            chunkDuration: chunk, windowDuration: window,
            diarizationChunkDuration: accum,
            expectedSpeakerCount: -1,
            profileStrategy: .registrationGate(minSeparation: 0.4),
            label: "gate_04_ami"
        )
    }

    // MARK: - Combined (cull 10/2 + merge 0.6)

    func testCombined_callhome_en() async throws {
        let _ = try await runDiarizationBenchmark(
            dataset: "callhome_en", maxConversations: 5,
            chunkDuration: chunk, windowDuration: window,
            diarizationChunkDuration: accum,
            expectedSpeakerCount: 2,
            profileStrategy: .combined(cullInterval: 10, minHits: 2, mergeThreshold: 0.6),
            label: "combined_en"
        )
    }

    func testCombined_callhome_ja() async throws {
        let _ = try await runDiarizationBenchmark(
            dataset: "callhome_ja", maxConversations: 5,
            chunkDuration: chunk, windowDuration: window,
            diarizationChunkDuration: accum,
            expectedSpeakerCount: 2,
            profileStrategy: .combined(cullInterval: 10, minHits: 2, mergeThreshold: 0.6),
            label: "combined_ja"
        )
    }

    func testCombined_ami() async throws {
        let _ = try await runDiarizationBenchmark(
            dataset: "ami", maxConversations: 5,
            chunkDuration: chunk, windowDuration: window,
            diarizationChunkDuration: accum,
            expectedSpeakerCount: -1,
            profileStrategy: .combined(cullInterval: 10, minHits: 2, mergeThreshold: 0.6),
            label: "combined_ami"
        )
    }
}
