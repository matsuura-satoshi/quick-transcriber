import XCTest
@testable import QuickTranscriberLib

final class ConfusionPairAnalysisTests: DiarizationBenchmarkTestBase {
    /// Standing roster of regulars present in the production store (see plan roster assumption).
    static let roster = ["松浦", "今村", "上東", "森", "森谷", "神野"]
    static let productionProfilePath = NSString(string: "~/QuickTranscriber/speakers.json").expandingTildeInPath

    struct RosterSimilarityArtifact: Codable {
        let speakers: [String]
        let matrix: [[Float]]          // matrix[i][j] = cos(speakers[i], speakers[j])
        let topPairs: [Pair]           // sorted descending, i<j
        struct Pair: Codable { let a: String; let b: String; let similarity: Float }
    }

    func testStaticRosterSimilarity() throws {
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: Self.productionProfilePath),
            "production speakers.json not present"
        )
        let profiles = try SpeakerProfileLoader.load(
            path: Self.productionProfilePath,
            displayNames: Self.roster
        )
        // Preserve roster order for a stable matrix.
        let ordered = Self.roster.compactMap { name in profiles.first { $0.displayName == name } }
        XCTAssertEqual(ordered.count, Self.roster.count)

        var matrix = [[Float]](repeating: [Float](repeating: 0, count: ordered.count), count: ordered.count)
        var pairs: [RosterSimilarityArtifact.Pair] = []
        for i in 0..<ordered.count {
            for j in 0..<ordered.count {
                let sim = EmbeddingBasedSpeakerTracker.cosineSimilarity(ordered[i].embedding, ordered[j].embedding)
                matrix[i][j] = sim
                if i < j {
                    pairs.append(.init(a: ordered[i].displayName, b: ordered[j].displayName, similarity: sim))
                }
            }
        }
        pairs.sort { $0.similarity > $1.similarity }

        // Invariants
        for i in 0..<ordered.count {
            XCTAssertEqual(matrix[i][i], 1.0, accuracy: 0.01, "diagonal must be 1")
            for j in 0..<ordered.count {
                XCTAssertEqual(matrix[i][j], matrix[j][i], accuracy: 1e-5, "matrix must be symmetric")
            }
        }
        // Pre-registered finding: 神野 is within the top similarity neighbourhood of an active speaker.
        let kaminoToUehigashi = simBetween(matrix, ordered, "神野", "上東")
        let kaminoToMori = simBetween(matrix, ordered, "神野", "森")
        XCTAssertGreaterThan(kaminoToUehigashi, 0.70, "神野 should be close to 上東 (observed ~0.764)")
        XCTAssertGreaterThan(kaminoToMori, 0.70, "神野 should be close to 森 (observed ~0.768)")

        let artifact = RosterSimilarityArtifact(
            speakers: ordered.map(\.displayName), matrix: matrix, topPairs: pairs
        )
        let outURL = URL(fileURLWithPath: "/tmp/confusion_roster_similarity.json")
        try JSONEncoder().encode(artifact).write(to: outURL, options: .atomic)
        NSLog("[ConfusionPair] roster similarity written: \(outURL.path)")
        for p in pairs.prefix(6) {
            NSLog("[ConfusionPair] pair \(p.a)<->\(p.b): \(String(format: "%.3f", p.similarity))")
        }
    }

    private func simBetween(_ m: [[Float]], _ ordered: [LoadedSpeakerProfile], _ a: String, _ b: String) -> Float {
        guard let i = ordered.firstIndex(where: { $0.displayName == a }),
              let j = ordered.firstIndex(where: { $0.displayName == b }) else { return 0 }
        return m[i][j]
    }

    struct RealSession {
        let dirName: String
        let registered: [String]   // Manual-mode participant roster (must exist in store)
        let qtStartSecondsOfDay: Double
        let audioDurationSeconds: Double
    }

    static let sessions: [RealSession] = [
        RealSession(dirName: "2026-04-21_CERTインシデント情報共有",
                    registered: ["松浦", "今村", "上東", "森", "森谷", "神野"],
                    qtStartSecondsOfDay: 9*3600 + 44*60 + 23,
                    audioDurationSeconds: 695),
        RealSession(dirName: "2026-04-23_CERTインシデント情報共有",
                    registered: ["松浦", "今村", "上東", "森", "森谷", "神野"],
                    qtStartSecondsOfDay: 9*3600 + 44*60 + 48,
                    audioDurationSeconds: 904),
    ]

    /// Zoom handle → short name. Reverse of the plan's mapping table.
    static let zoomToShort: [String: String] = [
        "松浦 知史 / Science Tokyo CERT / MATSUURA Satoshi": "松浦",
        "今村＠情報セキュリティ室": "今村",
        "Y.Uehigashi": "上東",
        "佐々木@情報セキュリティ室": "佐々木",
        "Kento Mori": "森",
        "moriya": "森谷",
    ]

    static let sessionsRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents/QuickTranscriber/real-sessions")

    /// Replay one WAV through the Manual-mode diarizer; return per-chunk
    /// (startSeconds, endSeconds, predictedUUID) for confirmed (non-pending) chunks.
    private func replay(
        session: RealSession,
        idToName: inout [String: String]
    ) async throws -> [(start: Double, end: Double, predicted: String)] {
        let dir = Self.sessionsRoot.appendingPathComponent(session.dirName)
        let wavURL = dir.appendingPathComponent("audio.wav")

        let loaded = try SpeakerProfileLoader.load(
            path: Self.productionProfilePath,
            displayNames: session.registered
        )
        let participants = loaded.map { (speakerId: $0.id, embedding: $0.embedding) }
        for p in loaded { idToName[p.id.uuidString] = p.displayName }

        let diarizer = FluidAudioSpeakerDiarizer(
            similarityThreshold: Constants.Embedding.similarityThreshold,
            windowDuration: 15.0,
            diarizationChunkDuration: 7.0,
            expectedSpeakerCount: participants.count
        )
        try await diarizer.setup()
        diarizer.loadSpeakerProfiles(participants)
        diarizer.setSuppressLearning(true)

        let smoother = ViterbiSpeakerSmoother(stayProbability: 0.9)

        // VAD-chunk the audio (100ms increments), tracking absolute audio time.
        let samples = try loadAudioSamples(from: wavURL.path)
        var acc = VADChunkAccumulator(
            maxChunkDuration: Constants.VAD.defaultMaxChunkDuration,
            endOfUtteranceSilence: Constants.VAD.defaultEndOfUtteranceSilence,
            silenceEnergyThreshold: Constants.VAD.defaultSilenceEnergyThreshold,
            speechOnsetThreshold: Constants.VAD.defaultSpeechOnsetThreshold,
            preRollDuration: Constants.VAD.defaultPreRollDuration,
            hangoverDuration: Constants.VAD.defaultHangoverDuration
        )
        let sr = Constants.Audio.sampleRateInt
        let inc = Int(0.1 * Double(sr))

        struct PendingChunk { let start: Double; let end: Double }
        var out: [(start: Double, end: Double, predicted: String)] = []
        var pendingChunks: [PendingChunk] = []   // chunks awaiting Viterbi confirmation

        var lastConfirmed: String? = nil
        var offset = 0
        var emittedEnd = 0

        func handle(chunk: ChunkResult, endSample: Int) async {
            let endT = Double(endSample) / Double(sr)
            let startT = endT - Double(chunk.samples.count) / Double(sr)
            let significantSilence = chunk.precedingSilenceDuration >= Constants.VAD.defaultEndOfUtteranceSilence
            if significantSilence { smoother.resetForSpeakerChange() }
            let raw = await diarizer.identifySpeaker(
                audioChunk: chunk.samples, forceRun: significantSilence, utteranceId: chunk.utteranceId
            )
            let smoothed = smoother.process(raw)
            if let s = smoothed {
                let id = s.speakerId.uuidString
                lastConfirmed = id
                // Retroactively flush any pending chunks to this confirmed id.
                for pc in pendingChunks { out.append((pc.start, pc.end, id)) }
                pendingChunks.removeAll()
                out.append((startT, endT, id))
            } else {
                pendingChunks.append(PendingChunk(start: startT, end: endT))
            }
        }

        while offset < samples.count {
            let end = min(offset + inc, samples.count)
            emittedEnd = end
            if let chunk = acc.appendBuffer(Array(samples[offset..<end])) {
                await handle(chunk: chunk, endSample: emittedEnd)
            }
            offset = end
        }
        if let chunk = acc.flush() {
            await handle(chunk: chunk, endSample: emittedEnd)
        }
        // Any still-pending chunks inherit the last confirmed speaker.
        if let last = lastConfirmed {
            for pc in pendingChunks { out.append((pc.start, pc.end, last)) }
        }
        out.sort { $0.start < $1.start }
        return out
    }
}
