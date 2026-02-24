import Foundation
import SwiftUI
import AppKit
import Combine

public enum ModelState: Equatable {
    case notLoaded
    case loading
    case ready
    case error(String)
}

@MainActor
public final class TranscriptionViewModel: ObservableObject {
    @Published public var unconfirmedText: String = ""
    @Published public var isRecording: Bool = false
    @Published public var currentLanguage: Language = {
        if let raw = UserDefaults.standard.string(forKey: "selectedLanguage"),
           let lang = Language(rawValue: raw) {
            return lang
        }
        return .english
    }()
    @Published public var modelState: ModelState = .notLoaded
    @Published public var fontSize: CGFloat = 15.0
    @Published public var confirmedSegments: [ConfirmedSegment] = []

    public var confirmedText: String {
        guard !confirmedSegments.isEmpty else { return "" }
        return TranscriptionUtils.joinSegments(
            confirmedSegments,
            language: currentLanguage.rawValue,
            silenceThreshold: parametersStore.parameters.silenceLineBreakThreshold,
            speakerDisplayNames: speakerDisplayNames
        )
    }
    @Published public var speakerProfiles: [StoredSpeakerProfile] = []
    @Published public var speakerDisplayNames: [String: String] = [:]
    @Published public var activeSpeakers: [ActiveSpeaker] = []
    public var speakerMenuOrder: [String] = []
    @Published public var preExistingProfileIds: Set<UUID> = []
    @Published public var showPostMeetingTagging: Bool = false
    @Published public var translationEnabled: Bool = UserDefaults.standard.bool(forKey: "translationEnabled")
    public let translationService = TranslationService()

    public var silenceLineBreakThreshold: TimeInterval {
        parametersStore.parameters.silenceLineBreakThreshold
    }

    public var translationTargetLanguage: Language {
        currentLanguage == .english ? .japanese : .english
    }

    private var service: TranscriptionService
    private let modelName: String
    internal let parametersStore: ParametersStore
    internal let speakerProfileStore: SpeakerProfileStore
    private let embeddingHistoryStore: EmbeddingHistoryStore
    private let fileWriter: TranscriptFileWriter
    private var fileSessionActive: Bool = false
    private var previousSessionSegments: [ConfirmedSegment] = []
    private var nextSpeakerNumber: Int = 1
    var trackerAliases: [String: UUID] = [:]
    var removedSpeakerIds: Set<UUID> = []
    private var cancellables: Set<AnyCancellable> = []

    public init(
        engine: TranscriptionEngine? = nil,
        modelName: String = "large-v3-v20240930_turbo",
        parametersStore: ParametersStore? = nil,
        fileWriter: TranscriptFileWriter? = nil,
        diarizer: SpeakerDiarizer? = nil,
        speakerProfileStore: SpeakerProfileStore? = nil,
        embeddingHistoryStore: EmbeddingHistoryStore? = nil
    ) {
        UserDefaults.standard.register(defaults: ["showPostMeetingSheet": true])
        let resolvedStore = parametersStore ?? ParametersStore.shared
        let profileStore = speakerProfileStore ?? {
            let store = SpeakerProfileStore()
            do {
                try store.load()
            } catch {
                NSLog("[QuickTranscriber] Failed to load speaker profiles: \(error)")
            }
            return store
        }()
        self.speakerProfileStore = profileStore
        self.speakerProfiles = profileStore.profiles
        let resolvedEmbeddingHistoryStore = embeddingHistoryStore ?? EmbeddingHistoryStore()
        self.embeddingHistoryStore = resolvedEmbeddingHistoryStore
        // Always create diarizer so it's available when the user enables it at runtime.
        // The enableSpeakerDiarization parameter controls whether it's actually used.
        let resolvedEngine = engine ?? ChunkedWhisperEngine(
            diarizer: diarizer ?? FluidAudioSpeakerDiarizer(),
            speakerProfileStore: profileStore,
            embeddingHistoryStore: resolvedEmbeddingHistoryStore
        )
        self.service = TranscriptionService(engine: resolvedEngine)
        self.modelName = modelName
        self.parametersStore = resolvedStore
        self.fileWriter = fileWriter ?? TranscriptFileWriter()

        resolvedStore.$parameters
            .dropFirst()
            .removeDuplicates()
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.isRecording else { return }
                NSLog("[QuickTranscriber] Parameters changed, restarting recording")
                self.restartRecording()
            }
            .store(in: &cancellables)

        // Only restart when manual speakers change (not auto-detected additions)
        // map+removeDuplicates before dropFirst so the initial [] is used as baseline
        $activeSpeakers
            .map { $0.filter { $0.source == .manual } }
            .removeDuplicates()
            .dropFirst()
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self,
                      self.isRecording,
                      self.parametersStore.parameters.diarizationMode == .manual
                else { return }
                NSLog("[QuickTranscriber] Active speakers (manual) changed, restarting recording")
                self.restartRecording()
            }
            .store(in: &cancellables)

        $isRecording
            .sink { UserDefaults.standard.set($0, forKey: "isRecording") }
            .store(in: &cancellables)

        $translationEnabled
            .sink { UserDefaults.standard.set($0, forKey: "translationEnabled") }
            .store(in: &cancellables)
    }

    public func loadModel() async {
        modelState = .loading
        NSLog("[QuickTranscriber] Loading model: \(modelName)")
        do {
            try await service.prepare(model: modelName)
            modelState = .ready
            NSLog("[QuickTranscriber] Model ready")
        } catch {
            modelState = .error(error.localizedDescription)
            NSLog("[QuickTranscriber] Model load error: \(error)")
        }
    }

    public func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    public func switchLanguage(_ language: Language) {
        let wasRecording = isRecording
        if wasRecording {
            saveUnconfirmedText()
            isRecording = false
        }

        if !previousSessionSegments.isEmpty {
            let previousLang = currentLanguage.displayName
            let newLang = language.displayName
            previousSessionSegments.append(ConfirmedSegment(
                text: "--- \(previousLang) → \(newLang) ---",
                precedingSilence: 1.0
            ))
            confirmedSegments = previousSessionSegments
            fileWriter.updateText(confirmedText)
        }

        currentLanguage = language
        UserDefaults.standard.set(language.rawValue, forKey: "selectedLanguage")
        translationService.reset()

        if wasRecording {
            Task {
                await service.stopTranscription()
                try? await Task.sleep(nanoseconds: 100_000_000)
                startRecording()
            }
        }
    }

    public func clearText() {
        let wasRecording = isRecording
        if wasRecording {
            isRecording = false
        }
        fileWriter.endSession()
        fileSessionActive = false
        previousSessionSegments = []
        confirmedSegments = []
        unconfirmedText = ""
        activeSpeakers = []
        trackerAliases = [:]
        removedSpeakerIds = []
        translationService.reset()
        if wasRecording {
            Task {
                await service.stopTranscription()
                try? await Task.sleep(nanoseconds: 100_000_000)
                startRecording()
            }
        }
    }

    public func increaseFontSize() {
        fontSize = min(fontSize + 1, 30)
    }

    public func decreaseFontSize() {
        fontSize = max(fontSize - 1, 10)
    }

    public func copyAllText() {
        let text = displayText
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    public func exportText() {
        let text = displayText
        guard !text.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "transcription.txt"
        panel.begin { response in
            if response == .OK, let url = panel.url {
                do {
                    try text.write(to: url, atomically: true, encoding: .utf8)
                    NSLog("[QuickTranscriber] Exported to: \(url.path)")
                } catch {
                    NSLog("[QuickTranscriber] Export error: \(error)")
                }
            }
        }
    }

    public var displayText: String {
        if unconfirmedText.isEmpty {
            return confirmedText
        }
        if confirmedText.isEmpty {
            return unconfirmedText
        }
        return confirmedText + "\n" + unconfirmedText
    }

    // MARK: - Active Speakers

    public struct SpeakerMenuItem: Equatable {
        public let id: UUID
        public let displayName: String?
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

    public func renameActiveSpeaker(id: UUID, displayName: String) {
        let name = displayName.isEmpty ? nil : displayName
        if let idx = activeSpeakers.firstIndex(where: { $0.id == id }) {
            activeSpeakers[idx].displayName = name
        }
        // Update stored profile if linked
        if let speaker = activeSpeakers.first(where: { $0.id == id }),
           let profileId = speaker.speakerProfileId {
            try? speakerProfileStore.rename(id: profileId, to: displayName)
            speakerProfiles = speakerProfileStore.profiles
        }
        updateSpeakerDisplayNames()
        regenerateText()
    }

    // MARK: - Speaker Reassignment

    public func splitSegment(at index: Int, offset: Int) {
        guard index < confirmedSegments.count else { return }
        let segment = confirmedSegments[index]
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

        confirmedSegments.replaceSubrange(index...index, with: [first, second])
    }

    private func reassignSegment(at index: Int, to newSpeaker: String) {
        guard index < confirmedSegments.count else { return }
        let originalSpeaker = confirmedSegments[index].speaker
        if let embedding = confirmedSegments[index].speakerEmbedding, let oldSpeaker = originalSpeaker {
            service.correctSpeakerAssignment(embedding: embedding, from: oldSpeaker, to: newSpeaker)
        }
        confirmedSegments[index].originalSpeaker = originalSpeaker
        confirmedSegments[index].speaker = newSpeaker
        confirmedSegments[index].speakerConfidence = 1.0
        confirmedSegments[index].isUserCorrected = true
    }

    public func reassignSpeakerForBlock(segmentIndex: Int, newSpeaker: String) {
        guard segmentIndex < confirmedSegments.count else { return }
        let targetSpeaker = confirmedSegments[segmentIndex].speaker

        // Find consecutive block with same speaker
        var startIdx = segmentIndex
        while startIdx > 0 && confirmedSegments[startIdx - 1].speaker == targetSpeaker {
            startIdx -= 1
        }
        var endIdx = segmentIndex
        while endIdx < confirmedSegments.count - 1 && confirmedSegments[endIdx + 1].speaker == targetSpeaker {
            endIdx += 1
        }

        for i in startIdx...endIdx {
            reassignSegment(at: i, to: newSpeaker)
        }

        recordSpeakerSelection(newSpeaker)
        regenerateText()
        translationService.syncSpeakerMetadata(from: confirmedSegments)
    }

    public func reassignSpeakerForSelection(
        selectionRange: NSRange,
        newSpeaker: String,
        segmentMap: SegmentCharacterMap
    ) {
        let indices = segmentMap.segmentIndices(overlapping: selectionRange)
        guard !indices.isEmpty else { return }

        // Process splits from end to start to avoid index shifting
        let sortedIndices = indices.sorted(by: >)

        for idx in sortedIndices {
            guard idx < confirmedSegments.count else { continue }
            let entry = segmentMap.entries.first { $0.segmentIndex == idx }
            guard let entry else { continue }

            let charRange = entry.characterRange
            let overlapStart = max(selectionRange.location, charRange.location)
            let overlapEnd = min(NSMaxRange(selectionRange), NSMaxRange(charRange))

            if overlapStart <= charRange.location && overlapEnd >= NSMaxRange(charRange) {
                // Fully selected — just reassign
                reassignSegment(at: idx, to: newSpeaker)
            } else {
                // Partially selected — need to split
                let localStart = overlapStart - charRange.location
                let localEnd = overlapEnd - charRange.location

                // Split at end first (to preserve indices)
                if localEnd < charRange.length {
                    splitSegment(at: idx, offset: localEnd)
                }
                // Now split at start
                let splitIdx = idx
                if localStart > 0 {
                    splitSegment(at: splitIdx, offset: localStart)
                    // The selected portion is now at splitIdx + 1
                    reassignSegment(at: splitIdx + 1, to: newSpeaker)
                } else {
                    reassignSegment(at: splitIdx, to: newSpeaker)
                }
            }
        }

        recordSpeakerSelection(newSpeaker)
        regenerateText()
        translationService.syncSpeakerMetadata(from: confirmedSegments)
    }

    public func regenerateText() {
        fileWriter.updateText(confirmedText)
    }

    // MARK: - Speaker Profile Management

    public func renameSpeaker(id: UUID, to name: String) {
        do {
            try speakerProfileStore.rename(id: id, to: name)
        } catch {
            NSLog("[QuickTranscriber] Failed to rename speaker \(id): \(error)")
        }
        speakerProfiles = speakerProfileStore.profiles
    }

    public func setLocked(id: UUID, locked: Bool) {
        do {
            try speakerProfileStore.setLocked(id: id, locked: locked)
        } catch {
            NSLog("[QuickTranscriber] Failed to set locked state for \(id): \(error)")
        }
        speakerProfiles = speakerProfileStore.profiles
    }

    public func deleteSpeaker(id: UUID) {
        do {
            try speakerProfileStore.delete(id: id)
        } catch {
            NSLog("[QuickTranscriber] Failed to delete speaker \(id): \(error)")
        }
        speakerProfiles = speakerProfileStore.profiles
        activeSpeakers.removeAll { $0.speakerProfileId == id }
        embeddingHistoryStore.removeEntries(for: Set([id]))
        updateSpeakerDisplayNames()
    }

    public func deleteAllSpeakers() {
        speakerProfileStore.deleteAll()
        speakerProfiles = []
        speakerDisplayNames = [:]
        embeddingHistoryStore.removeAll()
    }

    // MARK: - Tags

    public var allTags: [String] {
        speakerProfileStore.allTags
    }

    public func addTag(_ tag: String, to profileId: UUID) {
        do {
            try speakerProfileStore.addTag(tag, to: profileId)
        } catch {
            NSLog("[QuickTranscriber] Failed to add tag '\(tag)' to profile \(profileId): \(error)")
        }
        speakerProfiles = speakerProfileStore.profiles
    }

    public func removeTag(_ tag: String, from profileId: UUID) {
        do {
            try speakerProfileStore.removeTag(tag, from: profileId)
        } catch {
            NSLog("[QuickTranscriber] Failed to remove tag '\(tag)' from profile \(profileId): \(error)")
        }
        speakerProfiles = speakerProfileStore.profiles
    }

    public func addManualSpeakersByTag(_ tag: String) {
        let taggedProfiles = speakerProfileStore.profiles(withTag: tag)
        for profile in taggedProfiles {
            addManualSpeaker(fromProfile: profile.id)
        }
    }

    public func addManualSpeakers(profileIds: [UUID]) {
        for id in profileIds {
            addManualSpeaker(fromProfile: id)
        }
    }

    public func bulkAddTag(_ tag: String, to profileIds: [UUID]) {
        let trimmed = tag.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !profileIds.isEmpty else { return }
        for id in profileIds {
            addTag(trimmed, to: id)
        }
    }

    // MARK: - Active Speaker Management

    public func addManualSpeaker(fromProfile profileId: UUID) {
        guard let profile = speakerProfileStore.profiles.first(where: { $0.id == profileId }) else { return }

        // Already active with this profile linked — no-op
        if activeSpeakers.contains(where: { $0.speakerProfileId == profileId }) {
            return
        }

        // Auto-detected speaker with same ID but unlinked — update in-place
        if let idx = activeSpeakers.firstIndex(where: { $0.id == profileId }) {
            activeSpeakers[idx].speakerProfileId = profileId
            activeSpeakers[idx].displayName = profile.displayName
            updateSpeakerDisplayNames()
            return
        }

        // New speaker
        let speaker = ActiveSpeaker(
            id: profileId,
            speakerProfileId: profileId,
            displayName: profile.displayName,
            source: .manual
        )
        activeSpeakers.append(speaker)
        updateSpeakerDisplayNames()
    }

    func generateSpeakerName() -> String {
        let existingNames = Set(activeSpeakers.compactMap { $0.displayName })
            .union(speakerProfileStore.profiles.map { $0.displayName })
        while existingNames.contains("Speaker-\(nextSpeakerNumber)") {
            nextSpeakerNumber += 1
        }
        let name = "Speaker-\(nextSpeakerNumber)"
        nextSpeakerNumber += 1
        return name
    }

    public func addManualSpeaker(displayName: String) {
        let name: String
        if displayName.isEmpty {
            name = generateSpeakerName()
        } else {
            name = displayName
        }
        let speaker = ActiveSpeaker(displayName: name, source: .manual)
        activeSpeakers.append(speaker)
        updateSpeakerDisplayNames()
    }

    public func addAndReassignBlock(profileId: UUID, segmentIndex: Int) {
        addManualSpeaker(fromProfile: profileId)
        guard let speaker = activeSpeakers.last(where: { $0.speakerProfileId == profileId }) else { return }
        reassignSpeakerForBlock(segmentIndex: segmentIndex, newSpeaker: speaker.id.uuidString)
    }

    public func addAndReassignSelection(profileId: UUID, selectionRange: NSRange, segmentMap: SegmentCharacterMap) {
        addManualSpeaker(fromProfile: profileId)
        guard let speaker = activeSpeakers.last(where: { $0.speakerProfileId == profileId }) else { return }
        reassignSpeakerForSelection(selectionRange: selectionRange, newSpeaker: speaker.id.uuidString, segmentMap: segmentMap)
    }

    public func removeActiveSpeaker(id: UUID) {
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

    public func deleteSpeakers(ids: Set<UUID>) {
        do {
            try speakerProfileStore.deleteMultiple(ids: ids)
        } catch {
            NSLog("[QuickTranscriber] Failed to delete speakers: \(error)")
        }
        speakerProfiles = speakerProfileStore.profiles
        activeSpeakers.removeAll { speaker in
            guard let pid = speaker.speakerProfileId else { return false }
            return ids.contains(pid)
        }
        embeddingHistoryStore.removeEntries(for: ids)
        updateSpeakerDisplayNames()
    }

    public func clearActiveSpeakers(source: ActiveSpeaker.Source? = nil) {
        if let source {
            activeSpeakers.removeAll { $0.source == source }
        } else {
            activeSpeakers = []
        }
        trackerAliases = [:]
    }

    /// Add an auto-detected speaker from the diarization pipeline
    func addAutoDetectedSpeaker(speakerId: String, embedding: [Float]?) {
        // Block re-addition of removed speakers
        if let uuid = UUID(uuidString: speakerId), removedSpeakerIds.contains(uuid) { return }
        guard !activeSpeakers.contains(where: { $0.id.uuidString == speakerId }) else { return }

        var matchedProfileId: UUID? = nil
        if let embedding {
            var bestSimilarity: Float = -1
            for profile in speakerProfileStore.profiles {
                let sim = EmbeddingBasedSpeakerTracker.cosineSimilarity(embedding, profile.embedding)
                if sim >= Constants.Embedding.similarityThreshold && sim > bestSimilarity {
                    bestSimilarity = sim
                    matchedProfileId = profile.id
                }
            }
        }

        // Block re-addition of removed profiles
        if let matchedProfileId, removedSpeakerIds.contains(matchedProfileId) { return }

        // Profile already active — register tracker alias instead of adding duplicate
        if let matchedProfileId,
           let existing = activeSpeakers.first(where: { $0.speakerProfileId == matchedProfileId }) {
            trackerAliases[speakerId] = existing.id
            updateSpeakerDisplayNames()
            return
        }

        // Manual mode: only allow alias registration, block new speaker addition
        if parametersStore.parameters.diarizationMode == .manual {
            return
        }

        let displayName: String
        if let profileId = matchedProfileId,
           let profile = speakerProfileStore.profiles.first(where: { $0.id == profileId }) {
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

    // MARK: - Private

    private func updateSpeakerDisplayNames() {
        var names: [String: String] = [:]
        for speaker in activeSpeakers {
            if let name = speaker.displayName {
                names[speaker.id.uuidString] = name
            }
        }
        // Resolve tracker aliases to active speaker display names
        for (trackerUUID, activeSpeakerId) in trackerAliases {
            if let name = names[activeSpeakerId.uuidString] {
                names[trackerUUID] = name
            }
        }
        speakerDisplayNames = names
    }

    private func restartRecording() {
        saveUnconfirmedText()
        isRecording = false
        Task {
            await service.stopTranscription()
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms safety margin
            startRecording()
        }
    }

    private func startRecording() {
        guard modelState == .ready else {
            NSLog("[QuickTranscriber] Cannot record: model state = \(modelState)")
            return
        }
        isRecording = true
        let params = parametersStore.parameters
        NSLog("[QuickTranscriber] Starting recording, language: \(currentLanguage.rawValue), params: \(params)")

        if !fileSessionActive {
            fileWriter.startSession(language: currentLanguage, initialText: confirmedText)
            fileSessionActive = true
        } else if fileWriter.hasDirectoryChanged {
            fileWriter.endSession()
            fileWriter.startSession(language: currentLanguage, initialText: confirmedText)
        }

        // Resolve participant profiles for manual mode
        let participantProfiles: [(speakerId: UUID, embedding: [Float])]?
        if params.diarizationMode == .manual {
            let speakersWithProfiles = activeSpeakers.compactMap { speaker -> (speakerId: UUID, embedding: [Float])? in
                guard let profileId = speaker.speakerProfileId,
                      let stored = speakerProfileStore.profiles.first(where: { $0.id == profileId })
                else { return nil }
                return (speakerId: stored.id, embedding: stored.embedding)
            }
            participantProfiles = speakersWithProfiles.isEmpty ? nil : speakersWithProfiles
        } else {
            participantProfiles = nil
        }

        let sessionSegments = self.previousSessionSegments
        Task {
            do {
                try await service.startTranscription(
                    language: currentLanguage.rawValue,
                    parameters: params,
                    participantProfiles: participantProfiles
                ) { [weak self] state in
                    NSLog("[QuickTranscriber] State update - confirmed: \(state.confirmedText.count) chars, unconfirmed: \(state.unconfirmedText.count) chars")
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.unconfirmedText = state.unconfirmedText
                        // Derive segments from text if engine didn't provide them
                        var stateSegments = state.confirmedSegments
                        if stateSegments.isEmpty && !state.confirmedText.isEmpty {
                            stateSegments = [ConfirmedSegment(text: state.confirmedText)]
                        }
                        let newSegments: [ConfirmedSegment]
                        if sessionSegments.isEmpty {
                            newSegments = stateSegments
                        } else if stateSegments.isEmpty {
                            newSegments = sessionSegments
                        } else {
                            newSegments = sessionSegments + stateSegments
                        }
                        self.confirmedSegments = Self.mergePreservingUserCorrections(
                            existing: self.confirmedSegments,
                            incoming: newSegments
                        )

                        // Auto-detect new speakers from segments
                        for segment in stateSegments {
                            if let speakerId = segment.speaker {
                                self.addAutoDetectedSpeaker(speakerId: speakerId, embedding: segment.speakerEmbedding)
                            }
                        }

                        self.fileWriter.updateText(self.confirmedText)
                    }
                }
            } catch {
                NSLog("[QuickTranscriber] Recording error: \(error)")
                isRecording = false
            }
        }
    }

    private func saveUnconfirmedText() {
        if !unconfirmedText.isEmpty {
            let silence = confirmedSegments.isEmpty ? 0.0 : parametersStore.parameters.silenceLineBreakThreshold
            confirmedSegments.append(ConfirmedSegment(
                text: unconfirmedText,
                precedingSilence: silence
            ))
            unconfirmedText = ""
        }
        previousSessionSegments = confirmedSegments
    }

    static func mergePreservingUserCorrections(
        existing: [ConfirmedSegment],
        incoming: [ConfirmedSegment]
    ) -> [ConfirmedSegment] {
        guard !existing.isEmpty else { return incoming }
        var merged = incoming
        // Preserve user-corrected segments at their original indices
        for (i, segment) in existing.enumerated() {
            guard segment.isUserCorrected, i < merged.count else { continue }
            merged[i] = segment
        }
        return merged
    }

    private func stopRecording() {
        isRecording = false
        saveUnconfirmedText()
        fileWriter.updateText(confirmedText)
        // Snapshot existing profile IDs before merge (for "new" badge in PostMeetingTagSheet)
        preExistingProfileIds = Set(speakerProfileStore.profiles.map { $0.id })
        Task {
            await service.stopTranscription(speakerDisplayNames: self.speakerDisplayNames)
            self.speakerProfiles = self.speakerProfileStore.profiles
            self.linkActiveSpeakersToProfiles()
            if UserDefaults.standard.bool(forKey: "showPostMeetingSheet") {
                self.showPostMeetingTagging = true
            }
        }
    }

    func linkActiveSpeakersToProfiles() {
        var createdNewProfiles = false

        for i in activeSpeakers.indices where activeSpeakers[i].speakerProfileId == nil {
            let speakerId = activeSpeakers[i].id

            // Priority 1: Direct ID match (session UUID == profile UUID from RC2 fix)
            if speakerProfileStore.profiles.contains(where: { $0.id == speakerId }) {
                activeSpeakers[i].speakerProfileId = speakerId
                continue
            }

            // Priority 1.5: Tracker alias — match profiles created under aliased tracker UUIDs
            let aliasedTrackerUUIDs = trackerAliases
                .filter { $0.value == speakerId }
                .compactMap { UUID(uuidString: $0.key) }
            var linkedViaAlias = false
            for aliasUUID in aliasedTrackerUUIDs {
                if speakerProfileStore.profiles.contains(where: { $0.id == aliasUUID }) {
                    activeSpeakers[i].speakerProfileId = aliasUUID
                    linkedViaAlias = true
                    break
                }
            }
            if linkedViaAlias { continue }

            // Priority 2: Embedding similarity fallback
            let speakerIdString = speakerId.uuidString
            guard let embedding = confirmedSegments.first(where: {
                $0.speaker == speakerIdString
            })?.speakerEmbedding else { continue }

            var bestIndex = -1
            var bestSimilarity: Float = -1
            for (j, profile) in speakerProfileStore.profiles.enumerated() {
                let sim = EmbeddingBasedSpeakerTracker.cosineSimilarity(embedding, profile.embedding)
                if sim > bestSimilarity {
                    bestSimilarity = sim
                    bestIndex = j
                }
            }
            if bestIndex >= 0 && bestSimilarity >= Constants.Embedding.similarityThreshold {
                activeSpeakers[i].speakerProfileId = speakerProfileStore.profiles[bestIndex].id
            } else {
                // Create new profile for unlinked speaker
                let displayName = activeSpeakers[i].displayName ?? generateSpeakerName()
                let newProfile = StoredSpeakerProfile(id: speakerId, displayName: displayName, embedding: embedding)
                speakerProfileStore.profiles.append(newProfile)
                activeSpeakers[i].speakerProfileId = speakerId
                createdNewProfiles = true
            }
        }

        if createdNewProfiles {
            try? speakerProfileStore.save()
            speakerProfiles = speakerProfileStore.profiles
        }
    }

}
