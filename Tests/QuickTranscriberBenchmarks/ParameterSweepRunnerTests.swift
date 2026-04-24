import XCTest
@testable import QuickTranscriberLib

final class ParameterSweepRunnerManifestTests: XCTestCase {
    func test_parseManifest_readsConfigsWithOverrides() throws {
        let json = """
        {
          "stage": 1,
          "outputPath": "/tmp/out.json",
          "configs": [
            {
              "id": "baseline",
              "dataset": "fleurs_en",
              "subsetSeed": 20260424,
              "subsetSize": 100,
              "overrides": {
                "chunkDuration": 8.0,
                "silenceCutoffDuration": 0.6,
                "sampleLength": 224
              }
            },
            {
              "id": "chunkDuration_6",
              "dataset": "fleurs_en",
              "subsetSeed": 20260424,
              "subsetSize": 100,
              "overrides": { "chunkDuration": 6.0 }
            }
          ]
        }
        """.data(using: .utf8)!

        let manifest = try ParameterSweepRunner.parseManifest(json)

        XCTAssertEqual(manifest.stage, 1)
        XCTAssertEqual(manifest.outputPath, "/tmp/out.json")
        XCTAssertEqual(manifest.configs.count, 2)
        XCTAssertEqual(manifest.configs[0].id, "baseline")
        XCTAssertEqual(manifest.configs[0].dataset, "fleurs_en")
        XCTAssertEqual(manifest.configs[0].subsetSeed, 20260424)
        XCTAssertEqual(manifest.configs[0].subsetSize, 100)
        XCTAssertEqual(manifest.configs[0].overrides["chunkDuration"]?.doubleValue, 8.0)
        XCTAssertEqual(manifest.configs[0].overrides["sampleLength"]?.intValue, 224)
        XCTAssertEqual(manifest.configs[1].overrides.count, 1)
    }

    func test_value_decodesAllPrimitives() throws {
        struct Wrapper: Codable {
            let b: ParameterSweepRunner.Value
            let i: ParameterSweepRunner.Value
            let d: ParameterSweepRunner.Value
            let s: ParameterSweepRunner.Value
        }
        let json = """
        { "b": true, "i": 42, "d": 3.14, "s": "hello" }
        """.data(using: .utf8)!

        let w = try JSONDecoder().decode(Wrapper.self, from: json)

        XCTAssertEqual(w.b.boolValue, true)
        XCTAssertEqual(w.i.intValue, 42)
        XCTAssertEqual(w.d.doubleValue, 3.14)
        XCTAssertEqual(w.s.stringValue, "hello")
    }

    func test_apply_mutatesKnownTranscriptionParameterFields() {
        var params = TranscriptionParameters.default
        let overrides: [String: ParameterSweepRunner.Value] = [
            "chunkDuration": .double(10.0),
            "silenceCutoffDuration": .double(0.8),
            "silenceEnergyThreshold": .double(0.02),
            "speechOnsetThreshold": .double(0.05),
            "preRollDuration": .double(0.5),
            "sampleLength": .int(128),
            "concurrentWorkerCount": .int(8),
            "temperatureFallbackCount": .int(2),
            "speakerTransitionPenalty": .double(0.9),
            "enableSpeakerDiarization": .bool(true),
            "suppressBlank": .bool(true),
        ]

        try? ParameterSweepRunner.apply(overrides: overrides, to: &params)

        XCTAssertEqual(params.chunkDuration, 10.0)
        XCTAssertEqual(params.silenceCutoffDuration, 0.8)
        XCTAssertEqual(params.silenceEnergyThreshold, 0.02)
        XCTAssertEqual(params.speechOnsetThreshold, 0.05)
        XCTAssertEqual(params.preRollDuration, 0.5)
        XCTAssertEqual(params.sampleLength, 128)
        XCTAssertEqual(params.concurrentWorkerCount, 8)
        XCTAssertEqual(params.temperatureFallbackCount, 2)
        XCTAssertEqual(params.speakerTransitionPenalty, 0.9)
        XCTAssertEqual(params.enableSpeakerDiarization, true)
        XCTAssertEqual(params.suppressBlank, true)
    }

    func test_apply_leavesStage2OnlyKeysInResidualBucket() throws {
        var params = TranscriptionParameters.default
        let overrides: [String: ParameterSweepRunner.Value] = [
            "chunkDuration": .double(10.0),
            "similarityThreshold": .double(0.6),
            "diarizationChunkDuration": .double(5.0),
            "windowDuration": .double(10.0),
            "profileStrategy": .string("culling"),
        ]

        let residual = try ParameterSweepRunner.apply(overrides: overrides, to: &params)

        XCTAssertEqual(params.chunkDuration, 10.0)
        XCTAssertEqual(residual["similarityThreshold"]?.doubleValue, 0.6)
        XCTAssertEqual(residual["diarizationChunkDuration"]?.doubleValue, 5.0)
        XCTAssertEqual(residual["windowDuration"]?.doubleValue, 10.0)
        XCTAssertEqual(residual["profileStrategy"]?.stringValue, "culling")
        XCTAssertNil(residual["chunkDuration"])
    }

    func test_apply_throwsOnUnknownKey() {
        var params = TranscriptionParameters.default
        let overrides: [String: ParameterSweepRunner.Value] = [
            "nonsenseParameter": .int(1)
        ]
        XCTAssertThrowsError(
            try ParameterSweepRunner.apply(overrides: overrides, to: &params)
        ) { error in
            guard case ParameterSweepRunner.ApplyError.unknownKey(let key) = error else {
                XCTFail("expected unknownKey, got \(error)")
                return
            }
            XCTAssertEqual(key, "nonsenseParameter")
        }
    }
}

final class ParameterSweepRunnerRunTests: XCTestCase {
    func test_run_dryRun_writesResultJsonWithOneEntryPerConfig() async throws {
        let tmpPath = "/tmp/test_sweep_\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }

        let manifest = ParameterSweepRunner.Manifest(
            stage: 1,
            outputPath: tmpPath,
            configs: [
                .init(id: "c1", dataset: "fixture_en", subsetSeed: 1, subsetSize: 1, overrides: [:]),
                .init(
                    id: "c2",
                    dataset: "fixture_en",
                    subsetSeed: 1,
                    subsetSize: 1,
                    overrides: ["sampleLength": .int(128)]
                )
            ]
        )

        try await ParameterSweepRunner.run(manifest: manifest, dryRun: true)

        let data = try Data(contentsOf: URL(fileURLWithPath: tmpPath))
        let results = try JSONDecoder().decode([ParameterSweepRunner.RunResult].self, from: data)
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(Set(results.map { $0.configId }), ["c1", "c2"])
        XCTAssertTrue(results.allSatisfy { $0.completed })
    }

    func test_run_skipsCompletedConfigs() async throws {
        let tmpPath = "/tmp/test_sweep_resume_\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }

        let preExisting = [
            ParameterSweepRunner.RunResult(
                configId: "c1",
                stage: 1,
                dataset: "fixture_en",
                metrics: ["wer": 0.1],
                latencyBreakdown: nil,
                completed: true
            )
        ]
        try JSONEncoder().encode(preExisting).write(to: URL(fileURLWithPath: tmpPath))

        let manifest = ParameterSweepRunner.Manifest(
            stage: 1,
            outputPath: tmpPath,
            configs: [
                .init(id: "c1", dataset: "fixture_en", subsetSeed: 1, subsetSize: 1, overrides: [:]),
                .init(id: "c2", dataset: "fixture_en", subsetSeed: 1, subsetSize: 1, overrides: [:])
            ]
        )

        try await ParameterSweepRunner.run(manifest: manifest, dryRun: true)

        let data = try Data(contentsOf: URL(fileURLWithPath: tmpPath))
        let results = try JSONDecoder().decode([ParameterSweepRunner.RunResult].self, from: data)
        XCTAssertEqual(results.count, 2)
        let c1 = results.first(where: { $0.configId == "c1" })
        XCTAssertEqual(c1?.metrics["wer"], 0.1, "c1 result should be preserved, not overwritten")
    }

    func test_run_persistsAfterEveryConfig() async throws {
        // Verify that partial progress is written after each config so a crash
        // mid-sweep keeps earlier results.
        let tmpPath = "/tmp/test_sweep_persist_\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }

        let manifest = ParameterSweepRunner.Manifest(
            stage: 1,
            outputPath: tmpPath,
            configs: (0..<5).map { i in
                ParameterSweepRunner.Config(
                    id: "c\(i)",
                    dataset: "fixture_en",
                    subsetSeed: 1,
                    subsetSize: 1,
                    overrides: [:]
                )
            }
        )

        try await ParameterSweepRunner.run(manifest: manifest, dryRun: true)

        let data = try Data(contentsOf: URL(fileURLWithPath: tmpPath))
        let results = try JSONDecoder().decode([ParameterSweepRunner.RunResult].self, from: data)
        XCTAssertEqual(results.count, 5)
    }
}
