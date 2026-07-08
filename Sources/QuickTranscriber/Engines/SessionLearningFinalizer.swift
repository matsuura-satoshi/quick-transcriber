import Foundation

/// stopStreaming 時のセッション事後学習を engine から独立して実行する。
/// manual モードの post-hoc 学習 / auto モードの session profile マージ /
/// embedding history 保存の 3 責務を持ち、音声パイプラインなしで単体テストできる。
struct SessionLearningFinalizer {
    let profileStore: SpeakerProfileStore?
    let embeddingHistoryStore: EmbeddingHistoryStore?

    /// diarizer から export 済みの値を受け取り、セッション終了時の学習一式を実行する。
    func finalize(
        mode: DiarizationMode,
        participantIds: Set<UUID>,
        segments: [ConfirmedSegment],
        speakerDisplayNames: [String: String],
        sessionProfiles: [(speakerId: UUID, embedding: [Float])],
        detailedProfiles: [(speakerId: UUID, embedding: [Float], embeddingHistory: [WeightedEmbedding])]
    ) {
        if let store = profileStore {
            if mode == .manual && !participantIds.isEmpty {
                // Manual mode: confirmedSegments の非修正サンプルから weighted merge
                applyManualModePostHocLearning(participantIds: participantIds, segments: segments)
                do {
                    try store.save()
                } catch {
                    NSLog("[SessionLearningFinalizer] Failed to save after post-hoc learning: \(error)")
                }
            } else {
                // Auto mode: 従来どおり tracker profile を merge
                mergeAutoModeSessionProfiles(
                    store: store,
                    sessionProfiles: sessionProfiles,
                    segments: segments,
                    speakerDisplayNames: speakerDisplayNames
                )
            }
        }
        saveEmbeddingHistory(detailedProfiles: detailedProfiles)
    }

    /// Manual mode の post-hoc 学習を実行する。
    /// Tracker 側は session 中、auto 判定の混入を避けるため centroid を控えめに扱い、
    /// 手動訂正は信頼サンプルとして扱う。session 終了時にはその両方を集めて
    /// store 側 profile centroid を緩やかに更新する。
    ///
    /// 前提: user がラベルを付け替えた segment は「現時点の正解」。ラベルを
    /// 付け替えていない segment は auto 推定の結果にすぎず、ground truth とは
    /// 見なさない（user が監視役ではないため）。高 confidence フィルタだけに
    /// 頼り、修正 / 非修正で区別はしない。
    func applyManualModePostHocLearning(
        participantIds: Set<UUID>,
        segments: [ConfirmedSegment]
    ) {
        guard let store = profileStore else { return }
        for participantId in participantIds {
            let samples = segments.filter { seg in
                seg.speaker == participantId.uuidString
                    && (seg.speakerConfidence ?? 0) >= Constants.Embedding.similarityThreshold
                    && seg.speakerEmbedding != nil
            }

            guard samples.count >= Constants.Embedding.sessionLearningMinSamples else { continue }
            guard let existing = store.profiles.first(where: { $0.id == participantId }),
                  !existing.isLocked else { continue }

            let embeddings = samples.compactMap { $0.speakerEmbedding }
            guard let centroid = EmbeddingMath.weightedMean(embeddings.map { (embedding: $0, weight: 1.0) }) else { continue }

            let alpha = min(
                Constants.Embedding.sessionLearningAlphaMax,
                Float(samples.count) / Float(Constants.Embedding.sessionLearningSamplesForMaxAlpha)
            )
            store.applyPostHocLearning(
                speakerId: participantId,
                sessionCentroid: centroid,
                alpha: alpha
            )
            NSLog("[SessionLearningFinalizer] Post-hoc learning for \(participantId): \(samples.count) samples, alpha=\(alpha)")
        }
    }

    private func mergeAutoModeSessionProfiles(
        store: SpeakerProfileStore,
        sessionProfiles: [(speakerId: UUID, embedding: [Float])],
        segments: [ConfirmedSegment],
        speakerDisplayNames: [String: String]
    ) {
        guard !sessionProfiles.isEmpty else { return }
        let correctedOriginalSpeakers = Set(
            segments
                .filter { $0.isUserCorrected }
                .compactMap { $0.originalSpeaker }
        )
        let filteredProfiles: [(speakerId: UUID, embedding: [Float])]
        if correctedOriginalSpeakers.isEmpty {
            filteredProfiles = sessionProfiles
        } else {
            filteredProfiles = sessionProfiles.filter { !correctedOriginalSpeakers.contains($0.speakerId.uuidString) }
            NSLog("[SessionLearningFinalizer] Skipping merge for corrected speakers: \(correctedOriginalSpeakers)")
        }
        guard !filteredProfiles.isEmpty else { return }
        let mergeProfiles = filteredProfiles.compactMap { profile
            -> (speakerId: UUID, embedding: [Float], displayName: String)? in
            guard let name = speakerDisplayNames[profile.speakerId.uuidString] else {
                NSLog("[SessionLearningFinalizer] Skipping unmapped profile \(profile.speakerId)")
                return nil
            }
            return (speakerId: profile.speakerId, embedding: profile.embedding, displayName: name)
        }
        guard !mergeProfiles.isEmpty else { return }
        store.mergeSessionProfiles(mergeProfiles)
        do {
            try store.save()
        } catch {
            NSLog("[SessionLearningFinalizer] Failed to save speaker profiles: \(error)")
        }
        NSLog("[SessionLearningFinalizer] Saved \(mergeProfiles.count) speaker profiles to store (filtered \(sessionProfiles.count - mergeProfiles.count))")
    }

    /// Save embedding history for future profile reconstruction
    private func saveEmbeddingHistory(
        detailedProfiles: [(speakerId: UUID, embedding: [Float], embeddingHistory: [WeightedEmbedding])]
    ) {
        guard let historyStore = embeddingHistoryStore else { return }
        let entries = detailedProfiles.compactMap { profile -> EmbeddingHistoryEntry? in
            guard !profile.embeddingHistory.isEmpty else { return nil }
            // Match with stored profile to get UUID
            let storedProfile = profileStore?.profiles.first { $0.id == profile.speakerId }
            let profileId = storedProfile?.id ?? profile.speakerId
            return EmbeddingHistoryEntry(
                speakerProfileId: profileId,
                label: profile.speakerId.uuidString,
                sessionDate: Date(),
                embeddings: profile.embeddingHistory.map { entry in
                    HistoricalEmbedding(embedding: entry.embedding, confirmed: true, confidence: entry.confidence)
                }
            )
        }
        if !entries.isEmpty {
            historyStore.appendSession(entries: entries)
            NSLog("[SessionLearningFinalizer] Saved \(entries.count) speaker histories")
        }
    }
}
