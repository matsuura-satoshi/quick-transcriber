import Foundation
import AppKit

public struct SpeakerMenuItem: Equatable {
    public let id: UUID
    public let displayName: String?
}

@MainActor
public final class SpeakerStateCoordinator {

    // MARK: - State

    public var activeSpeakers: [ActiveSpeaker] = []
    public private(set) var speakerDisplayNames: [String: String] = [:]
    public var historicalSpeakerNames: [String: String] = [:]
    public var trackerAliases: [String: UUID] = [:]
    public var removedSpeakerIds: Set<UUID> = []
    public var pendingProfileDeletions: Set<UUID> = []
    public var speakerMenuOrder: [String] = []
    var nextSpeakerNumber: Int = 1
    var recordingDiarizationMode: DiarizationMode = .auto

    // MARK: - Dependencies

    let profileStore: SpeakerProfileStore
    let embeddingHistoryStore: EmbeddingHistoryStore
    private weak var service: TranscriptionService?

    public init(profileStore: SpeakerProfileStore, embeddingHistoryStore: EmbeddingHistoryStore) {
        self.profileStore = profileStore
        self.embeddingHistoryStore = embeddingHistoryStore
    }

    func setService(_ service: TranscriptionService) {
        self.service = service
    }

    // MARK: - Reset

    func reset() {
        activeSpeakers = []
        speakerDisplayNames = [:]
        trackerAliases = [:]
        removedSpeakerIds = []
        historicalSpeakerNames = [:]
        pendingProfileDeletions = []
    }

    // MARK: - Name / Display

    func updateSpeakerDisplayNames() {
        var names = historicalSpeakerNames
        for speaker in activeSpeakers {
            if let name = speaker.displayName {
                names[speaker.id.uuidString] = name
            }
        }
        for (trackerUUID, activeSpeakerId) in trackerAliases {
            if let name = names[activeSpeakerId.uuidString] {
                names[trackerUUID] = name
            }
        }
        speakerDisplayNames = names
    }

    func findAvailableSpeakerNumber(startingFrom start: Int) -> Int {
        let existingNames = Set(activeSpeakers.compactMap { $0.displayName })
            .union(profileStore.profiles.map { $0.displayName })
        var n = start
        while existingNames.contains("Speaker-\(n)") {
            n += 1
        }
        return n
    }

    public var nextSpeakerPlaceholder: String {
        "Speaker-\(findAvailableSpeakerNumber(startingFrom: nextSpeakerNumber))"
    }

    func generateSpeakerName() -> String {
        let n = findAvailableSpeakerNumber(startingFrom: nextSpeakerNumber)
        let name = "Speaker-\(n)"
        nextSpeakerNumber = n + 1
        return name
    }

    public var availableSpeakers: [SpeakerMenuItem] {
        var speakersById: [String: ActiveSpeaker] = [:]
        for speaker in activeSpeakers {
            let key = speaker.id.uuidString
            if speakersById[key] == nil {
                speakersById[key] = speaker
            }
        }
        let activeIds = Set(speakersById.keys)

        var ordered: [SpeakerMenuItem] = []
        var seen = Set<String>()
        for idStr in speakerMenuOrder {
            guard activeIds.contains(idStr), !seen.contains(idStr),
                  let speaker = speakersById[idStr] else { continue }
            ordered.append(SpeakerMenuItem(id: speaker.id, displayName: speaker.displayName))
            seen.insert(idStr)
        }
        for speaker in activeSpeakers where !seen.contains(speaker.id.uuidString) {
            if seen.insert(speaker.id.uuidString).inserted {
                ordered.append(SpeakerMenuItem(id: speaker.id, displayName: speaker.displayName))
            }
        }
        return ordered
    }

    public func recordSpeakerSelection(_ idStr: String) {
        speakerMenuOrder.removeAll { $0 == idStr }
        speakerMenuOrder.insert(idStr, at: 0)
    }

    // MARK: - Active Speaker Management

    public func addManualSpeaker(fromProfile profileId: UUID) {
        guard let profile = profileStore.profiles.first(where: { $0.id == profileId }) else { return }

        if activeSpeakers.contains(where: { $0.speakerProfileId == profileId }) {
            return
        }

        if let idx = activeSpeakers.firstIndex(where: { $0.id == profileId }) {
            activeSpeakers[idx].speakerProfileId = profileId
            activeSpeakers[idx].displayName = profile.displayName
            updateSpeakerDisplayNames()
            return
        }

        let speaker = ActiveSpeaker(
            id: profileId,
            speakerProfileId: profileId,
            displayName: profile.displayName,
            source: .manual
        )
        activeSpeakers.append(speaker)
        updateSpeakerDisplayNames()
    }

    public func addManualSpeaker(displayName: String) {
        let name: String
        if displayName.isEmpty {
            name = generateSpeakerName()
        } else {
            name = displayName
        }

        if !name.isEmpty {
            if activeSpeakers.contains(where: { $0.displayName?.caseInsensitiveCompare(name) == .orderedSame }) {
                return
            }

            if let existingProfile = profileStore.profiles.first(where: {
                $0.displayName.caseInsensitiveCompare(name) == .orderedSame
            }) {
                addManualSpeaker(fromProfile: existingProfile.id)
                return
            }
        }

        let speaker = ActiveSpeaker(displayName: name, source: .manual)
        activeSpeakers.append(speaker)
        updateSpeakerDisplayNames()
    }

    public func addManualSpeakersByTag(_ tag: String) {
        let taggedProfiles = profileStore.profiles(withTag: tag)
        for profile in taggedProfiles {
            addManualSpeaker(fromProfile: profile.id)
        }
    }

    public func addManualSpeakers(profileIds: [UUID]) {
        for id in profileIds {
            addManualSpeaker(fromProfile: id)
        }
    }

    public func removeActiveSpeaker(id: UUID) {
        if let name = speakerDisplayNames[id.uuidString] {
            historicalSpeakerNames[id.uuidString] = name
        }
        if let speaker = activeSpeakers.first(where: { $0.id == id }),
           let profileId = speaker.speakerProfileId {
            removedSpeakerIds.insert(profileId)
        }
        removedSpeakerIds.insert(id)
        activeSpeakers.removeAll { $0.id == id }
        trackerAliases = trackerAliases.filter { $0.value != id }
        updateSpeakerDisplayNames()
    }

    public var activeProfileIds: Set<UUID> {
        Set(activeSpeakers.compactMap { $0.speakerProfileId })
    }

    public func deactivateSpeaker(profileId: UUID) {
        activeSpeakers.removeAll { $0.speakerProfileId == profileId }
    }

    public func bulkActivateProfiles(ids: [UUID]) {
        for id in ids {
            addManualSpeaker(fromProfile: id)
        }
    }

    public func bulkDeactivateProfiles(ids: Set<UUID>) {
        activeSpeakers.removeAll { speaker in
            guard let pid = speaker.speakerProfileId else { return false }
            return ids.contains(pid)
        }
    }

    public func clearActiveSpeakers(source: ActiveSpeaker.Source? = nil) {
        if let source {
            activeSpeakers.removeAll { $0.source == source }
        } else {
            activeSpeakers = []
        }
        trackerAliases = [:]
    }

    func addAutoDetectedSpeaker(speakerId: String, embedding: [Float]?) {
        if let uuid = UUID(uuidString: speakerId), removedSpeakerIds.contains(uuid) { return }
        guard !activeSpeakers.contains(where: { $0.id.uuidString == speakerId }) else { return }

        let matchedProfile = UUID(uuidString: speakerId).flatMap { id in
            profileStore.profiles.first(where: { $0.id == id })
        }
        let matchedProfileId = matchedProfile?.id

        if let matchedProfileId, removedSpeakerIds.contains(matchedProfileId) { return }

        if let matchedProfileId,
           let existing = activeSpeakers.first(where: { $0.speakerProfileId == matchedProfileId }) {
            trackerAliases[speakerId] = existing.id
            updateSpeakerDisplayNames()
            return
        }

        if recordingDiarizationMode == .manual {
            return
        }

        let displayName: String
        if let profile = matchedProfile {
            displayName = profile.displayName
        } else {
            displayName = generateSpeakerName()
        }

        let speaker = ActiveSpeaker(
            id: UUID(uuidString: speakerId) ?? UUID(),
            speakerProfileId: matchedProfileId,
            displayName: displayName,
            source: .autoDetected
        )
        activeSpeakers.append(speaker)
        updateSpeakerDisplayNames()
    }

    // MARK: - Speaker Changes

    func reassignSegment(at index: Int, to newSpeaker: String, segments: inout [ConfirmedSegment]) {
        guard index < segments.count else { return }
        let originalSpeaker = segments[index].speaker

        if let oldSpeaker = originalSpeaker {
            if let embedding = segments[index].speakerEmbedding {
                service?.correctSpeakerAssignment(
                    embedding: embedding, from: oldSpeaker, to: newSpeaker)
            } else {
                service?.syncViterbiConfirm(to: newSpeaker)
            }
        }

        segments[index].originalSpeaker = originalSpeaker
        segments[index].speaker = newSpeaker
        segments[index].speakerConfidence = 1.0
        segments[index].isUserCorrected = true
    }

    public func reassignSpeakerForBlock(segmentIndex: Int, newSpeaker: String, segments: inout [ConfirmedSegment]) {
        guard segmentIndex < segments.count else { return }
        let targetSpeaker = segments[segmentIndex].speaker

        var startIdx = segmentIndex
        while startIdx > 0 && segments[startIdx - 1].speaker == targetSpeaker {
            startIdx -= 1
        }
        var endIdx = segmentIndex
        while endIdx < segments.count - 1 && segments[endIdx + 1].speaker == targetSpeaker {
            endIdx += 1
        }

        for i in startIdx...endIdx {
            reassignSegment(at: i, to: newSpeaker, segments: &segments)
        }

        recordSpeakerSelection(newSpeaker)
    }

    public func reassignSpeakerForSelection(
        selectionRange: NSRange,
        newSpeaker: String,
        segmentMap: SegmentCharacterMap,
        segments: inout [ConfirmedSegment],
        onSplit: ((Int) -> Void)? = nil
    ) {
        let indices = segmentMap.segmentIndices(overlapping: selectionRange)
        guard !indices.isEmpty else { return }

        let sortedIndices = indices.sorted(by: >)

        for idx in sortedIndices {
            guard idx < segments.count else { continue }
            let entry = segmentMap.entries.first { $0.segmentIndex == idx }
            guard let entry else { continue }

            let charRange = entry.characterRange
            let overlapStart = max(selectionRange.location, charRange.location)
            let overlapEnd = min(NSMaxRange(selectionRange), NSMaxRange(charRange))

            if overlapStart <= charRange.location && overlapEnd >= NSMaxRange(charRange) {
                reassignSegment(at: idx, to: newSpeaker, segments: &segments)
            } else {
                let localStart = overlapStart - charRange.location
                let localEnd = overlapEnd - charRange.location

                if localEnd < charRange.length {
                    splitSegment(at: idx, offset: localEnd, segments: &segments)
                    onSplit?(idx)
                }
                let splitIdx = idx
                if localStart > 0 {
                    splitSegment(at: splitIdx, offset: localStart, segments: &segments)
                    onSplit?(splitIdx)
                    reassignSegment(at: splitIdx + 1, to: newSpeaker, segments: &segments)
                } else {
                    reassignSegment(at: splitIdx, to: newSpeaker, segments: &segments)
                }
            }
        }

        recordSpeakerSelection(newSpeaker)
    }

    func splitSegment(at index: Int, offset: Int, segments: inout [ConfirmedSegment]) {
        guard index < segments.count else { return }
        let segment = segments[index]
        guard offset > 0 && offset < segment.text.count else { return }

        let textStartIndex = segment.text.startIndex
        let splitIndex = segment.text.index(textStartIndex, offsetBy: offset)

        let firstText = String(segment.text[textStartIndex..<splitIndex])
        let secondText = String(segment.text[splitIndex...])

        var first = segment
        first.text = firstText

        var second = segment
        second.text = secondText
        second.precedingSilence = 0

        segments.replaceSubrange(index...index, with: [first, second])
    }

    public func executeMerge(
        _ request: SpeakerMergeRequest,
        segments: inout [ConfirmedSegment],
        isRecording: Bool
    ) {
        let sourceProfileId = resolveProfileId(for: request.sourceEntity)
        let targetProfileId = resolveProfileId(for: request.targetEntity)

        let sourceProfile = sourceProfileId.flatMap { id in profileStore.profiles.first(where: { $0.id == id }) }
        let targetProfile = targetProfileId.flatMap { id in profileStore.profiles.first(where: { $0.id == id }) }

        let sourceSessionCount = sourceProfile?.sessionCount ?? 0
        let targetSessionCount = targetProfile?.sessionCount ?? 0

        let survivorIsTarget = targetSessionCount >= sourceSessionCount
        let survivorEntity = survivorIsTarget ? request.targetEntity : request.sourceEntity
        let absorbedEntity = survivorIsTarget ? request.sourceEntity : request.targetEntity
        let survivorProfileId = survivorIsTarget ? targetProfileId : sourceProfileId
        let absorbedProfileId = survivorIsTarget ? sourceProfileId : targetProfileId

        let survivorId = entityUUID(survivorEntity)
        let absorbedId = entityUUID(absorbedEntity)

        // 1. Segment reassignment: absorbed → survivor
        let absorbedIdStr = absorbedId.uuidString
        let survivorIdStr = survivorId.uuidString
        for i in segments.indices {
            if segments[i].speaker == absorbedIdStr {
                segments[i].speaker = survivorIdStr
            }
        }

        // 2. Tracker aliases remap
        for (key, value) in trackerAliases {
            if value == absorbedId {
                trackerAliases[key] = survivorId
            }
        }

        // 3. Profile integration (if both have profiles)
        if let survId = survivorProfileId, let absId = absorbedProfileId,
           let survIdx = profileStore.profiles.firstIndex(where: { $0.id == survId }),
           let absIdx = profileStore.profiles.firstIndex(where: { $0.id == absId }) {
            let absProfile = profileStore.profiles[absIdx]

            let totalSessions = profileStore.profiles[survIdx].sessionCount
                + absProfile.sessionCount
            let alpha: Float = totalSessions > 0
                ? Float(absProfile.sessionCount) / Float(totalSessions)
                : 0.5
            profileStore.profiles[survIdx].embedding = zip(
                profileStore.profiles[survIdx].embedding,
                absProfile.embedding
            ).map { survEmb, absEmb in
                (1 - alpha) * survEmb + alpha * absEmb
            }

            profileStore.profiles[survIdx].sessionCount += absProfile.sessionCount
            profileStore.profiles[survIdx].lastUsed = max(
                profileStore.profiles[survIdx].lastUsed,
                absProfile.lastUsed
            )
            let existingTags = Set(profileStore.profiles[survIdx].tags)
            for tag in absProfile.tags where !existingTags.contains(tag) {
                profileStore.profiles[survIdx].tags.append(tag)
            }
            profileStore.profiles[survIdx].isLocked = profileStore.profiles[survIdx].isLocked || absProfile.isLocked

            try? profileStore.forceDelete(id: absId)
            embeddingHistoryStore.removeEntries(for: Set([absId]))
        }

        // 4. Tracker integration (if recording)
        if isRecording, let survId = survivorProfileId, let absId = absorbedProfileId {
            service?.mergeSpeakerProfiles(from: absId, into: survId)
        }

        // 5. Active speaker update
        if let idx = activeSpeakers.firstIndex(where: { $0.id == survivorId }) {
            activeSpeakers[idx].displayName = request.duplicateName
        }
        activeSpeakers.removeAll { $0.id == absorbedId }

        // 6. Refresh
        updateSpeakerDisplayNames()
    }

    public func renameActiveSpeaker(id: UUID, displayName: String) {
        guard !displayName.isEmpty else { return }
        if let idx = activeSpeakers.firstIndex(where: { $0.id == id }) {
            activeSpeakers[idx].displayName = displayName
        }
        if let speaker = activeSpeakers.first(where: { $0.id == id }),
           let profileId = speaker.speakerProfileId {
            try? profileStore.rename(id: profileId, to: displayName)
        }
        updateSpeakerDisplayNames()
    }

    // MARK: - Profile Management / Lifecycle

    public func deleteSpeaker(id: UUID, isRecording: Bool) {
        activeSpeakers.removeAll { $0.speakerProfileId == id }
        updateSpeakerDisplayNames()

        if isRecording {
            pendingProfileDeletions.insert(id)
        } else {
            do {
                try profileStore.delete(id: id)
            } catch {
                NSLog("[QuickTranscriber] Failed to delete speaker \(id): \(error)")
            }
            embeddingHistoryStore.removeEntries(for: Set([id]))
        }
    }

    public func deleteAllSpeakers() {
        profileStore.deleteAll()
        speakerDisplayNames = [:]
        embeddingHistoryStore.removeAll()
    }

    public func deleteSpeakers(ids: Set<UUID>, isRecording: Bool) {
        activeSpeakers.removeAll { speaker in
            guard let pid = speaker.speakerProfileId else { return false }
            return ids.contains(pid)
        }
        updateSpeakerDisplayNames()

        if isRecording {
            pendingProfileDeletions.formUnion(ids)
        } else {
            do {
                try profileStore.deleteMultiple(ids: ids)
            } catch {
                NSLog("[QuickTranscriber] Failed to delete speakers: \(error)")
            }
            embeddingHistoryStore.removeEntries(for: ids)
        }
    }

    public func renameSpeaker(id: UUID, to name: String) {
        guard !name.isEmpty else { return }
        do {
            try profileStore.rename(id: id, to: name)
        } catch {
            NSLog("[QuickTranscriber] Failed to rename speaker \(id): \(error)")
        }
    }

    public func setLocked(id: UUID, locked: Bool) {
        do {
            try profileStore.setLocked(id: id, locked: locked)
        } catch {
            NSLog("[QuickTranscriber] Failed to set locked state for \(id): \(error)")
        }
    }

    /// Links unlinked active speakers to existing or new profiles.
    /// Returns true if new profiles were created.
    func linkActiveSpeakersToProfiles(segments: [ConfirmedSegment]) -> Bool {
        var createdNewProfiles = false

        for i in activeSpeakers.indices where activeSpeakers[i].speakerProfileId == nil {
            let speakerId = activeSpeakers[i].id

            // Priority 1: Direct ID match
            if profileStore.profiles.contains(where: { $0.id == speakerId }) {
                activeSpeakers[i].speakerProfileId = speakerId
                continue
            }

            // Priority 1.5: Tracker alias
            let aliasedTrackerUUIDs = trackerAliases
                .filter { $0.value == speakerId }
                .compactMap { UUID(uuidString: $0.key) }
            var linkedViaAlias = false
            for aliasUUID in aliasedTrackerUUIDs {
                if profileStore.profiles.contains(where: { $0.id == aliasUUID }) {
                    activeSpeakers[i].speakerProfileId = aliasUUID
                    linkedViaAlias = true
                    break
                }
            }
            if linkedViaAlias { continue }

            // Fallback: Create new profile for unlinked speaker
            let speakerIdString = speakerId.uuidString
            guard let embedding = segments.first(where: {
                $0.speaker == speakerIdString
            })?.speakerEmbedding else { continue }
            let displayName = activeSpeakers[i].displayName ?? generateSpeakerName()
            let newProfile = StoredSpeakerProfile(id: speakerId, displayName: displayName, embedding: embedding)
            profileStore.profiles.append(newProfile)
            activeSpeakers[i].speakerProfileId = speakerId
            createdNewProfiles = true
        }

        if createdNewProfiles {
            try? profileStore.save()
        }

        return createdNewProfiles
    }

    func flushPendingDeletions() {
        guard !pendingProfileDeletions.isEmpty else { return }
        let ids = pendingProfileDeletions
        pendingProfileDeletions = []
        do {
            try profileStore.deleteMultiple(ids: ids)
        } catch {
            NSLog("[QuickTranscriber] Failed to flush pending deletions: \(error)")
        }
        embeddingHistoryStore.removeEntries(for: ids)
    }

    func snapshotDiarizationMode(_ mode: DiarizationMode) {
        recordingDiarizationMode = mode
    }

    // MARK: - Private Helpers

    /// Verify speaker state invariants (DEBUG builds only).
    /// Call after mutations that modify both speaker state and segments.
    func verifyInvariants(segments: [ConfirmedSegment]) {
        SpeakerStateInvariantChecker.verify(
            segments: segments,
            activeSpeakers: activeSpeakers,
            historicalNames: historicalSpeakerNames,
            speakerDisplayNames: speakerDisplayNames,
            profileStore: profileStore
        )
    }

    private func resolveProfileId(for entity: SpeakerEntity) -> UUID? {
        switch entity {
        case .active(let id):
            return activeSpeakers.first(where: { $0.id == id })?.speakerProfileId
        case .registered(let id):
            return id
        }
    }

    private func entityUUID(_ entity: SpeakerEntity) -> UUID {
        switch entity {
        case .active(let id): return id
        case .registered(let id): return id
        }
    }
}
