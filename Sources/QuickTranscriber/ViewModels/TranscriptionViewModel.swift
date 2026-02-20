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
            labelDisplayNames: labelDisplayNames
        )
    }
    @Published public var speakerProfiles: [StoredSpeakerProfile] = []
    @Published public var labelDisplayNames: [String: String] = [:]
    @Published public var activeSpeakers: [ActiveSpeaker] = []
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
    private let fileWriter: TranscriptFileWriter
    private var fileSessionActive: Bool = false
    private var previousSessionSegments: [ConfirmedSegment] = []
    private var sessionRenamedLabels: Set<String> = []
    private var cancellables: Set<AnyCancellable> = []

    public init(
        engine: TranscriptionEngine? = nil,
        modelName: String = "large-v3-v20240930_turbo",
        parametersStore: ParametersStore? = nil,
        fileWriter: TranscriptFileWriter? = nil,
        diarizer: SpeakerDiarizer? = nil,
        speakerProfileStore: SpeakerProfileStore? = nil
    ) {
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
        self.labelDisplayNames = profileStore.labelDisplayNames
        // Always create diarizer so it's available when the user enables it at runtime.
        // The enableSpeakerDiarization parameter controls whether it's actually used.
        let resolvedEngine = engine ?? ChunkedWhisperEngine(
            diarizer: diarizer ?? FluidAudioSpeakerDiarizer(),
            speakerProfileStore: profileStore,
            embeddingHistoryStore: EmbeddingHistoryStore()
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

    public var availableSpeakers: [SpeakerMenuItem] {
        activeSpeakers.sorted(by: { $0.sessionLabel < $1.sessionLabel }).map {
            SpeakerMenuItem(label: $0.sessionLabel, displayName: $0.displayName)
        }
    }

    public struct SpeakerMenuItem: Equatable {
        public let label: String
        public let displayName: String?
    }

    public var registeredSpeakersForMenu: [RegisteredSpeakerInfo] {
        let activeIds = Set(activeSpeakers.compactMap { $0.speakerProfileId })
        return speakerProfileStore.profiles.map {
            RegisteredSpeakerInfo(
                profileId: $0.id,
                label: $0.label,
                displayName: $0.displayName,
                tags: $0.tags,
                isAlreadyActive: activeIds.contains($0.id)
            )
        }
    }

    public func renameActiveSpeaker(label: String, displayName: String) {
        labelDisplayNames[label] = displayName.isEmpty ? nil : displayName
        sessionRenamedLabels.insert(label)

        // Update activeSpeaker displayName
        if let idx = activeSpeakers.firstIndex(where: { $0.sessionLabel == label }) {
            activeSpeakers[idx].displayName = displayName.isEmpty ? nil : displayName
        }

        if let profile = speakerProfileStore.profiles.first(where: { $0.label == label }) {
            do {
                try speakerProfileStore.rename(id: profile.id, to: displayName)
            } catch {
                NSLog("[QuickTranscriber] Failed to rename session speaker '\(label)': \(error)")
            }
            speakerProfiles = speakerProfileStore.profiles
        }
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
        if let embedding = confirmedSegments[index].speakerEmbedding, let oldLabel = originalSpeaker {
            service.correctSpeakerAssignment(embedding: embedding, from: oldLabel, to: newSpeaker)
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
        labelDisplayNames = speakerProfileStore.labelDisplayNames
    }

    public func deleteSpeaker(id: UUID) {
        do {
            try speakerProfileStore.delete(id: id)
        } catch {
            NSLog("[QuickTranscriber] Failed to delete speaker \(id): \(error)")
        }
        speakerProfiles = speakerProfileStore.profiles
        labelDisplayNames = speakerProfileStore.labelDisplayNames
    }

    public func deleteAllSpeakers() {
        speakerProfileStore.deleteAll()
        speakerProfiles = []
        // Preserve display names for labels renamed during this session
        let sessionNames = sessionRenamedLabels.reduce(into: [String: String]()) { result, label in
            if let name = labelDisplayNames[label] { result[label] = name }
        }
        labelDisplayNames = sessionNames
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

    // MARK: - Active Speaker Management

    public func addManualSpeaker(fromProfile profileId: UUID) {
        guard let profile = speakerProfileStore.profiles.first(where: { $0.id == profileId }),
              !activeSpeakers.contains(where: { $0.speakerProfileId == profileId })
        else { return }
        let label = LabelUtils.nextAvailableLabel(
            usedLabels: Set(activeSpeakers.map { $0.sessionLabel })
        )
        activeSpeakers.append(ActiveSpeaker(
            speakerProfileId: profileId,
            sessionLabel: label,
            displayName: profile.displayName ?? profile.label,
            source: .manual
        ))
    }

    public func addManualSpeaker(displayName: String) {
        let label = LabelUtils.nextAvailableLabel(
            usedLabels: Set(activeSpeakers.map { $0.sessionLabel })
        )
        activeSpeakers.append(ActiveSpeaker(
            sessionLabel: label,
            displayName: displayName,
            source: .manual
        ))
        labelDisplayNames[label] = displayName
        sessionRenamedLabels.insert(label)
    }

    public func removeActiveSpeaker(id: UUID) {
        activeSpeakers.removeAll { $0.id == id }
    }

    public func clearActiveSpeakers(source: ActiveSpeaker.Source? = nil) {
        if let source {
            activeSpeakers.removeAll { $0.source == source }
        } else {
            activeSpeakers = []
        }
    }

    /// Add an auto-detected speaker from the diarization pipeline
    private func addAutoDetectedSpeaker(label: String, embedding: [Float]?) {
        guard !activeSpeakers.contains(where: { $0.sessionLabel == label }) else { return }

        // Try to match with a stored profile by embedding
        var matchedProfileId: UUID?
        var displayName: String?
        if let emb = embedding {
            if let matched = speakerProfileStore.profiles.first(where: { profile in
                EmbeddingBasedSpeakerTracker.cosineSimilarity(emb, profile.embedding) >= Constants.Embedding.similarityThreshold
            }) {
                matchedProfileId = matched.id
                displayName = matched.displayName
            }
        }
        // Fallback: try label match
        if matchedProfileId == nil {
            if let matched = speakerProfileStore.profiles.first(where: { $0.label == label }) {
                matchedProfileId = matched.id
                displayName = matched.displayName
            }
        }

        if let name = displayName {
            labelDisplayNames[label] = name
        }

        activeSpeakers.append(ActiveSpeaker(
            speakerProfileId: matchedProfileId,
            sessionLabel: label,
            displayName: displayName ?? labelDisplayNames[label],
            source: .autoDetected
        ))
    }

    // MARK: - Private

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
        let participantProfiles: [(label: String, embedding: [Float])]?
        if params.diarizationMode == .manual {
            let speakersWithProfiles = activeSpeakers.compactMap { speaker -> (label: String, embedding: [Float])? in
                guard let profileId = speaker.speakerProfileId,
                      let stored = speakerProfileStore.profiles.first(where: { $0.id == profileId })
                else { return nil }
                return (speaker.sessionLabel, stored.embedding)
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
                            if let label = segment.speaker {
                                self.addAutoDetectedSpeaker(label: label, embedding: segment.speakerEmbedding)
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
        let pendingNames = self.labelDisplayNames
        let renamedLabels = self.sessionRenamedLabels
        let speakers = self.activeSpeakers
        Task {
            await service.stopTranscription()
            // Apply display names only for labels explicitly renamed during this session
            for (label, name) in pendingNames {
                guard renamedLabels.contains(label) else { continue }
                if let profile = self.speakerProfileStore.profiles.first(where: { $0.label == label }) {
                    do {
                        try self.speakerProfileStore.rename(id: profile.id, to: name)
                    } catch {
                        NSLog("[QuickTranscriber] Failed to rename speaker '\(label)' on stop: \(error)")
                    }
                }
            }
            // Apply display names from new manual speakers (no embedding yet) to newly created profiles
            for speaker in speakers where speaker.source == .manual && speaker.speakerProfileId == nil {
                if let displayName = speaker.displayName,
                   let newProfile = self.speakerProfileStore.profiles.first(where: {
                       $0.label == speaker.sessionLabel && ($0.displayName == nil || $0.displayName!.isEmpty)
                   }) {
                    do {
                        try self.speakerProfileStore.rename(id: newProfile.id, to: displayName)
                    } catch {
                        NSLog("[QuickTranscriber] Failed to rename new speaker '\(displayName)': \(error)")
                    }
                }
            }
            self.speakerProfiles = self.speakerProfileStore.profiles
            self.labelDisplayNames = self.speakerProfileStore.labelDisplayNames
        }
    }

}
