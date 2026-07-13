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
                let sim = EmbeddingMath.cosineSimilarity(ordered[i].embedding, ordered[j].embedding)
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

    /// Zoom handle → short name (ground-truth side only).
    /// 神野 is intentionally ABSENT: it is a silent registered participant with no
    /// Zoom handle, so it never appears as ground truth. 神野 only ever appears as a
    /// PREDICTED label (resolved via `idToName` from the loaded profile), which is the
    /// whole point of the false-神野 analysis. 佐々木 appears here (it spoke in 2026-04-21)
    /// but is NOT in any `registered` roster (no usable profile), so it shows up only as a
    /// ground-truth row whose predictions land on other speakers.
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

    /// One simulated user correction applied during an oracle-corrections replay.
    struct OracleCorrection: Codable {
        let atEnd: Double            // audio time (s) of the corrected chunk's end
        let from: String             // wrong label (display name)
        let to: String               // ground-truth label (display name)
        let usedCachedEmbedding: Bool  // segment carried a pacer-cached embedding
        let embeddingWasNil: Bool      // segment had no embedding (syncViterbiConfirm path)
    }

    /// Replay one WAV through the Manual-mode diarizer, recording per-chunk
    /// diagnostics (raw pre-Viterbi label, per-profile cosines, cache state,
    /// smoothing path). When `oracleGT` is supplied, additionally simulates a
    /// zero-latency user correction (production `reassignSegment` path) on every
    /// own-confirmed chunk whose label contradicts ground truth — an UPPER BOUND
    /// on correction efficacy (real users correct later and less often).
    ///
    /// Fidelity assumptions (carry into the report's Limitations):
    /// - The recorded WAV is already normalized (QT writes normalized samples), so we
    ///   feed it raw — no re-normalization. An Int16→Float round-trip adds tiny quantization.
    /// - VAD parameters use Constants.VAD.default*, matching a factory-default session; a
    ///   session run with customized VAD settings would segment differently.
    /// - Chunk timestamps include pre-roll (~0.3s) and hangover (~0.15s), so boundary
    ///   attribution carries a ±sub-second window — acceptable for per-speaker aggregates.
    /// - Diagnostics record the system's own output; oracle corrections are listed
    ///   separately and do NOT rewrite the corrected chunk's recorded label.
    private func replay(
        session: RealSession,
        idToName: inout [String: String],
        oracleGT: [ZoomSegment]? = nil
    ) async throws -> (chunks: [ChunkDiagnostic], corrections: [OracleCorrection], finalCentroids: [String: [Float]]) {
        let dir = Self.sessionsRoot.appendingPathComponent(session.dirName)
        let wavURL = dir.appendingPathComponent("audio.wav")

        let loaded = try SpeakerProfileLoader.load(
            path: Self.productionProfilePath,
            displayNames: session.registered
        )
        let participants = loaded.map { (speakerId: $0.id, embedding: $0.embedding) }
        for p in loaded { idToName[p.id.uuidString] = p.displayName }
        // Local copy: inout parameters cannot be captured by the nested functions below.
        let nameById = idToName
        let uuidByName = Dictionary(uniqueKeysWithValues: loaded.map { ($0.displayName, $0.id) })

        // windowDuration 15 / diarizationChunkDuration 7 match the production defaults
        // (production builds FluidAudioSpeakerDiarizer() with no args; see TranscriptionViewModel).
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

        var diagnostics: [ChunkDiagnostic] = []
        var pendingIndices: [Int] = []   // diagnostics indices awaiting Viterbi confirmation
        var corrections: [OracleCorrection] = []
        // Persistence rule: a real user corrects labels that STAY wrong, not one-chunk
        // boundary lag (which self-heals on the next chunk and whose instant correction
        // just shifts the error onto the next speaker via the Viterbi reset). Trigger a
        // correction on the 2nd consecutive own-confirmed chunk with the same gt→pred error.
        var consecutiveWrongPair: (gt: String, pred: String, count: Int)? = nil

        var lastConfirmedName: String? = nil
        var prevRawEmbedding: [Float]? = nil
        var offset = 0
        var emittedEnd = 0

        func currentCentroidsByName() -> [String: [Float]] {
            var out: [String: [Float]] = [:]
            for p in diarizer.exportSpeakerProfiles() {
                if let name = nameById[p.speakerId.uuidString] { out[name] = p.embedding }
            }
            return out
        }

        func handle(chunk: ChunkResult, endSample: Int) async {
            let endT = Double(endSample) / Double(sr)
            let startT = endT - Double(chunk.samples.count) / Double(sr)
            let significantSilence = chunk.precedingSilenceDuration >= Constants.VAD.defaultEndOfUtteranceSilence
            if significantSilence { smoother.resetForSpeakerChange() }
            let raw = await diarizer.identifySpeaker(
                audioChunk: chunk.samples, forceRun: significantSilence, utteranceId: chunk.utteranceId
            )

            // A repeated embedding means the pacer returned its cached result
            // instead of diarizing this chunk's audio (fresh runs always produce
            // a new segment embedding).
            let cached = raw?.embedding != nil && raw?.embedding == prevRawEmbedding
            if let e = raw?.embedding { prevRawEmbedding = e }

            var cosines: [String: Float] = [:]
            if let e = raw?.embedding {
                for (name, centroid) in currentCentroidsByName() {
                    cosines[name] = EmbeddingMath.cosineSimilarity(e, centroid)
                }
            }
            let rawName = raw.flatMap { nameById[$0.speakerId.uuidString] }

            let smoothed = smoother.process(raw)
            if let s = smoothed {
                let name = nameById[s.speakerId.uuidString]
                lastConfirmedName = name
                // Retroactively flush any pending chunks to this confirmed label.
                for i in pendingIndices {
                    diagnostics[i] = diagnostics[i].withFinal(name, inherited: true)
                }
                pendingIndices.removeAll()
                diagnostics.append(ChunkDiagnostic(
                    start: startT, end: endT,
                    rawName: rawName, rawConfidence: raw?.confidence,
                    cached: cached, significantSilence: significantSilence,
                    smoothedName: name, finalName: name, inherited: false,
                    cosines: cosines,
                    embedding: raw?.embedding
                ))

                // Oracle correction: simulation of the production reassignSegment
                // path (SpeakerStateCoordinator.reassignSegment →
                // ChunkedWhisperEngine.correctSpeakerAssignment / syncViterbiConfirm),
                // triggered when the same gt→pred error persists for 2 consecutive
                // own-confirmed chunks (realistic user-noticing model).
                if let gtSegments = oracleGT,
                   let finalName = name,
                   let gtName = groundTruthShortName(chunkStart: startT, chunkEnd: endT, segments: gtSegments) {
                    if gtName != finalName {
                        if let prev = consecutiveWrongPair, prev.gt == gtName, prev.pred == finalName {
                            consecutiveWrongPair = (gtName, finalName, prev.count + 1)
                        } else {
                            consecutiveWrongPair = (gtName, finalName, 1)
                        }
                    } else {
                        consecutiveWrongPair = nil
                    }
                }
                if let gtSegments = oracleGT,
                   let finalName = name,
                   let pair = consecutiveWrongPair, pair.count >= 2,
                   let gtName = groundTruthShortName(chunkStart: startT, chunkEnd: endT, segments: gtSegments),
                   gtName != finalName,
                   let gtId = uuidByName[gtName],
                   let predId = uuidByName[finalName] {
                    consecutiveWrongPair = nil   // corrected; restart persistence tracking
                    if let emb = raw?.embedding {
                        // ConfirmedSegment.speakerEmbedding == rawSpeakerResult?.embedding
                        diarizer.correctSpeakerAssignment(embedding: emb, from: predId, to: gtId)
                        if smoother.confirmedSpeakerId == predId {
                            smoother.confirmSpeaker(gtId)
                        }
                        corrections.append(OracleCorrection(
                            atEnd: endT, from: finalName, to: gtName,
                            usedCachedEmbedding: cached, embeddingWasNil: false
                        ))
                    } else {
                        smoother.confirmSpeaker(gtId)
                        corrections.append(OracleCorrection(
                            atEnd: endT, from: finalName, to: gtName,
                            usedCachedEmbedding: false, embeddingWasNil: true
                        ))
                    }
                }
            } else {
                diagnostics.append(ChunkDiagnostic(
                    start: startT, end: endT,
                    rawName: rawName, rawConfidence: raw?.confidence,
                    cached: cached, significantSilence: significantSilence,
                    smoothedName: nil, finalName: nil, inherited: false,
                    cosines: cosines,
                    embedding: raw?.embedding
                ))
                pendingIndices.append(diagnostics.count - 1)
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
        if let last = lastConfirmedName {
            for i in pendingIndices {
                diagnostics[i] = diagnostics[i].withFinal(last, inherited: true)
            }
        } else if !pendingIndices.isEmpty {
            // Smoother never confirmed any speaker across the whole file — anomalous
            // (the first non-nil identifySpeaker normally confirms immediately). Surface
            // it loudly rather than returning a spuriously empty result.
            NSLog("[ConfusionPair] WARNING \(session.dirName): smoother never confirmed; \(pendingIndices.count) pending chunks dropped")
        }
        diagnostics.sort { $0.start < $1.start }
        return (diagnostics, corrections, currentCentroidsByName())
    }

    // MARK: - Part B: Real-session confusion matrix

    struct SessionConfusionArtifact: Codable {
        let session: String
        let registered: [String]
        let matrix: ConfusionMatrixResult
        let chunkCount: Int
        let attributedCount: Int   // chunks with a Zoom GT speaker
    }

    func testRealSessionConfusion() async throws {
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: Self.productionProfilePath),
            "production speakers.json not present"
        )
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: Self.sessionsRoot.path),
            "real-sessions directory not present"
        )

        var artifacts: [SessionConfusionArtifact] = []
        for session in Self.sessions {
            let dir = Self.sessionsRoot.appendingPathComponent(session.dirName)
            let zoomURL = dir.appendingPathComponent("zoom_transcript.txt")
            guard FileManager.default.fileExists(atPath: zoomURL.path) else {
                NSLog("[ConfusionPair] SKIP \(session.dirName): no zoom_transcript.txt"); continue
            }
            let zoomRaw = try String(contentsOf: zoomURL, encoding: .utf8)
            let gtSegments = try SessionTimeAligner.zoomSegmentsAudioRelative(
                zoomRaw: zoomRaw,
                qtStartSecondsOfDay: session.qtStartSecondsOfDay,
                audioDurationSeconds: session.audioDurationSeconds
            )

            var idToName: [String: String] = [:]
            let (chunks, _, _) = try await replay(session: session, idToName: &idToName)
            let predicted = chunks.filter { $0.finalName != nil }

            // Attribute each predicted chunk to a Zoom GT speaker by max overlap.
            var rows: [(gt: String, pred: String)] = []
            for chunk in predicted {
                guard let predName = chunk.finalName else { continue }
                guard let gtShort = groundTruthShortName(
                    chunkStart: chunk.start, chunkEnd: chunk.end, segments: gtSegments
                ) else { continue }
                rows.append((gt: gtShort, pred: predName))
            }

            // Speaker axis: registered roster ∪ any GT speaker seen (e.g. 佐々木).
            let gtSpeakers = Set(rows.map(\.gt))
            let speakers = (session.registered + gtSpeakers.sorted()).reduced()
            let matrix = ConfusionMatrixBuilder.build(
                rows: rows, speakers: speakers, falseTarget: "神野", silentSpeakers: ["神野"]
            )

            artifacts.append(SessionConfusionArtifact(
                session: session.dirName, registered: session.registered,
                matrix: matrix, chunkCount: predicted.count, attributedCount: rows.count
            ))

            NSLog("[ConfusionPair] \(session.dirName): chunks=\(predicted.count) attributed=\(rows.count) false神野=\(matrix.totalFalseTarget)")
            for (gt, n) in matrix.falseTargetByGroundTruth.sorted(by: { $0.value > $1.value }) {
                NSLog("[ConfusionPair]   神野⟵\(gt): \(n)")
            }
        }

        XCTAssertFalse(artifacts.isEmpty, "no sessions processed")
        let outURL = URL(fileURLWithPath: "/tmp/confusion_sessions.json")
        try JSONEncoder().encode(artifacts).write(to: outURL, options: .atomic)
        NSLog("[ConfusionPair] session confusion written: \(outURL.path)")
    }

    // MARK: - Priority 1: Stickiness diagnostic (window-swallow vs smoother-flip)

    struct StickinessRow: Codable {
        let start: Double
        let end: Double
        let gt: String
        let raw: String?
        let final: String
        let cause: MisattributionCause?   // nil = correctly attributed
        let cached: Bool
        let significantSilence: Bool
        let inherited: Bool
        let cosGT: Float?                 // cos(query, GT centroid)
        let cosPred: Float?               // cos(query, predicted centroid)
        let margin: Float?                // cosPred - cosGT (>0: pred genuinely closer)
        let cosines: [String: Float]      // cos(query, centroid) for every registered profile
        let embedding: [Float]?           // raw query embedding (offline what-if simulations)
    }

    struct StickinessArtifact: Codable {
        let session: String
        let totalAttributed: Int
        let misattributed: Int
        let splitByCause: [String: Int]
        let splitByPair: [String: [String: Int]]   // "gt→pred" → cause → count
        let rows: [StickinessRow]
    }

    /// Joins replay diagnostics with Zoom ground truth and classifies every
    /// misattributed chunk. Returns rows + aggregates for one session.
    private func diagnose(
        session: RealSession,
        chunks: [ChunkDiagnostic],
        gtSegments: [ZoomSegment]
    ) -> StickinessArtifact {
        var rows: [StickinessRow] = []
        var splitByCause: [MisattributionCause: Int] = [:]
        var splitByPair: [String: [String: Int]] = [:]

        for chunk in chunks {
            guard let final = chunk.finalName else { continue }
            guard let gt = groundTruthShortName(
                chunkStart: chunk.start, chunkEnd: chunk.end, segments: gtSegments
            ) else { continue }
            let cause = StickinessClassifier.classify(chunk: chunk, groundTruth: gt)
            let cosGT = chunk.cosines[gt]
            let cosPred = chunk.cosines[final]
            rows.append(StickinessRow(
                start: chunk.start, end: chunk.end, gt: gt, raw: chunk.rawName,
                final: final, cause: cause, cached: chunk.cached,
                significantSilence: chunk.significantSilence, inherited: chunk.inherited,
                cosGT: cosGT, cosPred: cosPred,
                margin: (cosGT != nil && cosPred != nil) ? cosPred! - cosGT! : nil,
                cosines: chunk.cosines,
                embedding: chunk.embedding
            ))
            if let cause {
                splitByCause[cause, default: 0] += 1
                splitByPair["\(gt)→\(final)", default: [:]][cause.rawValue, default: 0] += 1
            }
        }

        return StickinessArtifact(
            session: session.dirName,
            totalAttributed: rows.count,
            misattributed: rows.filter { $0.cause != nil }.count,
            splitByCause: Dictionary(uniqueKeysWithValues: splitByCause.map { ($0.key.rawValue, $0.value) }),
            splitByPair: splitByPair,
            rows: rows
        )
    }

    func testStickinessDiagnostic() async throws {
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: Self.productionProfilePath),
            "production speakers.json not present"
        )
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: Self.sessionsRoot.path),
            "real-sessions directory not present"
        )

        var artifacts: [StickinessArtifact] = []
        for session in Self.sessions {
            let dir = Self.sessionsRoot.appendingPathComponent(session.dirName)
            let zoomURL = dir.appendingPathComponent("zoom_transcript.txt")
            guard FileManager.default.fileExists(atPath: zoomURL.path) else {
                NSLog("[Stickiness] SKIP \(session.dirName): no zoom_transcript.txt"); continue
            }
            let zoomRaw = try String(contentsOf: zoomURL, encoding: .utf8)
            let gtSegments = try SessionTimeAligner.zoomSegmentsAudioRelative(
                zoomRaw: zoomRaw,
                qtStartSecondsOfDay: session.qtStartSecondsOfDay,
                audioDurationSeconds: session.audioDurationSeconds
            )

            var idToName: [String: String] = [:]
            let (chunks, _, _) = try await replay(session: session, idToName: &idToName)
            let artifact = diagnose(session: session, chunks: chunks, gtSegments: gtSegments)
            artifacts.append(artifact)

            NSLog("[Stickiness] \(session.dirName): attributed=\(artifact.totalAttributed) wrong=\(artifact.misattributed)")
            for (cause, n) in artifact.splitByCause.sorted(by: { $0.value > $1.value }) {
                NSLog("[Stickiness]   cause \(cause): \(n)")
            }
            for (pair, causes) in artifact.splitByPair.sorted(by: { $0.value.values.reduce(0, +) > $1.value.values.reduce(0, +) }) {
                let total = causes.values.reduce(0, +)
                let detail = causes.sorted { $0.value > $1.value }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
                NSLog("[Stickiness]   pair \(pair): \(total) (\(detail))")
            }
        }

        XCTAssertFalse(artifacts.isEmpty, "no sessions processed")
        let outURL = URL(fileURLWithPath: "/tmp/stickiness_baseline.json")
        try JSONEncoder().encode(artifacts).write(to: outURL, options: .atomic)
        NSLog("[Stickiness] baseline diagnostic written: \(outURL.path)")
    }

    // MARK: - Correction stickiness (does a manual correction hold?)

    struct CorrectionStickinessArtifact: Codable {
        let session: String
        let baselineMisattributed: Int
        let oracleMisattributed: Int          // with zero-latency oracle corrections
        let correctionsApplied: Int
        let correctionsUsingCachedEmbedding: Int
        let reverts: Int                      // next same-GT chunk returned to the SAME wrong label
        let revertWithinSeconds: [Double]     // time from correction to first revert
        let centroidPairsBefore: [String: Float]   // "A↔B" cos at load time
        let centroidPairsAfter: [String: Float]    // same pairs after oracle corrections
        let corrections: [OracleCorrection]
        let baselineRows: [StickinessRow]          // per-chunk rows, no-correction replay
        let oracleRows: [StickinessRow]            // per-chunk rows, oracle-correction replay
    }

    func testCorrectionStickiness() async throws {
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: Self.productionProfilePath),
            "production speakers.json not present"
        )
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: Self.sessionsRoot.path),
            "real-sessions directory not present"
        )

        var artifacts: [CorrectionStickinessArtifact] = []
        for session in Self.sessions {
            let dir = Self.sessionsRoot.appendingPathComponent(session.dirName)
            let zoomURL = dir.appendingPathComponent("zoom_transcript.txt")
            guard FileManager.default.fileExists(atPath: zoomURL.path) else {
                NSLog("[CorrStick] SKIP \(session.dirName): no zoom_transcript.txt"); continue
            }
            let zoomRaw = try String(contentsOf: zoomURL, encoding: .utf8)
            let gtSegments = try SessionTimeAligner.zoomSegmentsAudioRelative(
                zoomRaw: zoomRaw,
                qtStartSecondsOfDay: session.qtStartSecondsOfDay,
                audioDurationSeconds: session.audioDurationSeconds
            )

            // Baseline (no corrections) and oracle-corrections replays.
            var idToName: [String: String] = [:]
            let (baseChunks, _, _) = try await replay(session: session, idToName: &idToName)
            let baseline = diagnose(session: session, chunks: baseChunks, gtSegments: gtSegments)

            var idToName2: [String: String] = [:]
            let (oracleChunks, corrections, finalCentroids) = try await replay(
                session: session, idToName: &idToName2, oracleGT: gtSegments
            )
            let oracle = diagnose(session: session, chunks: oracleChunks, gtSegments: gtSegments)

            // Revert analysis: after correcting (from P → to G at t), find the next
            // own-confirmed chunk whose GT is G; a revert means it was labeled P again.
            var reverts = 0
            var revertDelays: [Double] = []
            for c in corrections {
                if let next = oracle.rows.first(where: { row in
                    row.start >= c.atEnd && row.gt == c.to && !row.inherited
                }) {
                    if next.final == c.from {
                        reverts += 1
                        revertDelays.append(next.end - c.atEnd)
                    }
                }
            }

            // Centroid drift on pairs involved in corrections (gt-side profile is the
            // only one mutated in Manual mode).
            let loaded = try SpeakerProfileLoader.load(
                path: Self.productionProfilePath, displayNames: session.registered
            )
            let loadedByName = Dictionary(uniqueKeysWithValues: loaded.map { ($0.displayName, $0.embedding) })
            var pairsBefore: [String: Float] = [:]
            var pairsAfter: [String: Float] = [:]
            let correctedPairs = Set(corrections.map { "\($0.to)↔\($0.from)" })
            for pairKey in correctedPairs {
                let parts = pairKey.components(separatedBy: "↔")
                guard parts.count == 2,
                      let beforeA = loadedByName[parts[0]], let beforeB = loadedByName[parts[1]],
                      let afterA = finalCentroids[parts[0]], let afterB = finalCentroids[parts[1]] else { continue }
                pairsBefore[pairKey] = EmbeddingMath.cosineSimilarity(beforeA, beforeB)
                pairsAfter[pairKey] = EmbeddingMath.cosineSimilarity(afterA, afterB)
            }

            let artifact = CorrectionStickinessArtifact(
                session: session.dirName,
                baselineMisattributed: baseline.misattributed,
                oracleMisattributed: oracle.misattributed,
                correctionsApplied: corrections.count,
                correctionsUsingCachedEmbedding: corrections.filter { $0.usedCachedEmbedding }.count,
                reverts: reverts,
                revertWithinSeconds: revertDelays,
                centroidPairsBefore: pairsBefore,
                centroidPairsAfter: pairsAfter,
                corrections: corrections,
                baselineRows: baseline.rows,
                oracleRows: oracle.rows
            )
            artifacts.append(artifact)

            NSLog("[CorrStick] \(session.dirName): baselineWrong=\(baseline.misattributed) oracleWrong=\(oracle.misattributed) corrections=\(corrections.count) reverts=\(reverts)")
            for (pair, before) in pairsBefore.sorted(by: { $0.key < $1.key }) {
                let after = pairsAfter[pair] ?? 0
                NSLog("[CorrStick]   centroid \(pair): \(String(format: "%.3f", before)) → \(String(format: "%.3f", after))")
            }
        }

        XCTAssertFalse(artifacts.isEmpty, "no sessions processed")
        let outURL = URL(fileURLWithPath: "/tmp/stickiness_corrections.json")
        try JSONEncoder().encode(artifacts).write(to: outURL, options: .atomic)
        NSLog("[CorrStick] correction stickiness written: \(outURL.path)")
    }

    /// Max-overlap Zoom GT speaker (short name) for a chunk time-range, nil if no overlap.
    private func groundTruthShortName(
        chunkStart: Double, chunkEnd: Double, segments: [ZoomSegment]
    ) -> String? {
        var overlapByShort: [String: Double] = [:]
        for seg in segments {
            let o = max(0, min(seg.endSeconds, chunkEnd) - max(seg.startSeconds, chunkStart))
            guard o > 0 else { continue }
            let short = Self.zoomToShort[seg.speaker] ?? seg.speaker
            overlapByShort[short, default: 0] += o
        }
        return overlapByShort.max(by: { $0.value < $1.value })?.key
    }
}

private extension Array where Element == String {
    func reduced() -> [String] {
        var seen = Set<String>(); var out: [String] = []
        for e in self where !seen.contains(e) { seen.insert(e); out.append(e) }
        return out
    }
}
