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
    @Published public var confirmedText: String = ""
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
    @Published public var confirmedSegments: [ConfirmedSegment] = [] {
        didSet { sessionSpeakerCache = nil }
    }
    @Published public var speakerProfiles: [StoredSpeakerProfile] = []
    @Published public var labelDisplayNames: [String: String] = [:]
    @Published public var meetingParticipants: [MeetingParticipant] = []
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
    private let parametersStore: ParametersStore
    private let speakerProfileStore: SpeakerProfileStore
    private let fileWriter: TranscriptFileWriter
    private var fileSessionActive: Bool = false
    private var previousSessionText: String = ""
    private var previousSessionSegments: [ConfirmedSegment] = []
    private var sessionRenamedLabels: Set<String> = []
    private var sessionSpeakerCache: [SessionSpeakerInfo]?
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
            try? store.load()
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

        $meetingParticipants
            .dropFirst()
            .removeDuplicates()
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self,
                      self.isRecording,
                      self.parametersStore.parameters.diarizationMode == .manual
                else { return }
                NSLog("[QuickTranscriber] Meeting participants changed, restarting recording")
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

        if !previousSessionText.isEmpty {
            let previousLang = currentLanguage.displayName
            let newLang = language.displayName
            previousSessionText += "\n--- \(previousLang) → \(newLang) ---\n"
            confirmedText = previousSessionText
            previousSessionSegments.append(ConfirmedSegment(
                text: "--- \(previousLang) → \(newLang) ---",
                precedingSilence: 1.0
            ))
            confirmedSegments = previousSessionSegments
            fileWriter.updateText(resolvedFileText())
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
        previousSessionText = ""
        previousSessionSegments = []
        confirmedText = ""
        confirmedSegments = []
        unconfirmedText = ""
        meetingParticipants = []
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

    // MARK: - Session Speakers

    public struct SessionSpeakerInfo: Identifiable {
        public let label: String
        public let storedProfileId: UUID?
        public let displayName: String?
        public var id: String { label }
    }

    public var sessionSpeakers: [SessionSpeakerInfo] {
        if let cached = sessionSpeakerCache { return cached }
        guard !confirmedSegments.isEmpty else { return [] }
        var seen = Set<String>()
        var result: [SessionSpeakerInfo] = []
        for segment in confirmedSegments {
            guard let label = segment.speaker, !seen.contains(label) else { continue }
            seen.insert(label)
            // Match by embedding if available, fall back to label match
            var storedProfile: StoredSpeakerProfile?
            if let emb = segment.speakerEmbedding {
                storedProfile = speakerProfileStore.profiles.first { profile in
                    EmbeddingBasedSpeakerTracker.cosineSimilarity(emb, profile.embedding) >= 0.5
                }
            }
            if storedProfile == nil {
                storedProfile = speakerProfileStore.profiles.first { $0.label == label }
            }
            result.append(SessionSpeakerInfo(
                label: label,
                storedProfileId: storedProfile?.id,
                displayName: labelDisplayNames[label]
            ))
        }
        sessionSpeakerCache = result
        return result
    }

    public func renameSessionSpeaker(label: String, displayName: String) {
        labelDisplayNames[label] = displayName.isEmpty ? nil : displayName
        sessionRenamedLabels.insert(label)
        if let profile = speakerProfileStore.profiles.first(where: { $0.label == label }) {
            try? speakerProfileStore.rename(id: profile.id, to: displayName)
            speakerProfiles = speakerProfileStore.profiles
        }
        regenerateText()
    }

    // MARK: - Speaker Reassignment

    public struct SpeakerMenuItem: Equatable {
        public let label: String
        public let displayName: String?
    }

    public var availableSpeakers: [SpeakerMenuItem] {
        var labels = Set<String>()
        for segment in confirmedSegments {
            if let speaker = segment.speaker {
                labels.insert(speaker)
            }
        }
        for key in labelDisplayNames.keys {
            labels.insert(key)
        }
        return labels.sorted().map { label in
            SpeakerMenuItem(label: label, displayName: labelDisplayNames[label])
        }
    }

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
            let originalSpeaker = confirmedSegments[i].speaker
            // Update tracker profiles for real-time correction feedback
            if let embedding = confirmedSegments[i].speakerEmbedding, let oldLabel = originalSpeaker {
                service.correctSpeakerAssignment(embedding: embedding, from: oldLabel, to: newSpeaker)
            }
            confirmedSegments[i].originalSpeaker = originalSpeaker
            confirmedSegments[i].speaker = newSpeaker
            confirmedSegments[i].speakerConfidence = 1.0
            confirmedSegments[i].isUserCorrected = true
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
                let originalSpeaker = confirmedSegments[idx].speaker
                if let embedding = confirmedSegments[idx].speakerEmbedding, let oldLabel = originalSpeaker {
                    service.correctSpeakerAssignment(embedding: embedding, from: oldLabel, to: newSpeaker)
                }
                confirmedSegments[idx].originalSpeaker = originalSpeaker
                confirmedSegments[idx].speaker = newSpeaker
                confirmedSegments[idx].speakerConfidence = 1.0
                confirmedSegments[idx].isUserCorrected = true
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
                    let targetIdx = splitIdx + 1
                    let originalSpeaker = confirmedSegments[targetIdx].speaker
                    if let embedding = confirmedSegments[targetIdx].speakerEmbedding, let oldLabel = originalSpeaker {
                        service.correctSpeakerAssignment(embedding: embedding, from: oldLabel, to: newSpeaker)
                    }
                    confirmedSegments[targetIdx].originalSpeaker = originalSpeaker
                    confirmedSegments[targetIdx].speaker = newSpeaker
                    confirmedSegments[targetIdx].speakerConfidence = 1.0
                    confirmedSegments[targetIdx].isUserCorrected = true
                } else {
                    let originalSpeaker = confirmedSegments[splitIdx].speaker
                    if let embedding = confirmedSegments[splitIdx].speakerEmbedding, let oldLabel = originalSpeaker {
                        service.correctSpeakerAssignment(embedding: embedding, from: oldLabel, to: newSpeaker)
                    }
                    confirmedSegments[splitIdx].originalSpeaker = originalSpeaker
                    confirmedSegments[splitIdx].speaker = newSpeaker
                    confirmedSegments[splitIdx].speakerConfidence = 1.0
                    confirmedSegments[splitIdx].isUserCorrected = true
                }
            }
        }

        regenerateText()
        translationService.syncSpeakerMetadata(from: confirmedSegments)
    }

    public func regenerateText() {
        confirmedText = TranscriptionUtils.joinSegments(
            confirmedSegments,
            language: currentLanguage.rawValue,
            silenceThreshold: parametersStore.parameters.silenceLineBreakThreshold,
            labelDisplayNames: labelDisplayNames
        )
        fileWriter.updateText(resolvedFileText())
    }

    // MARK: - Speaker Profile Management

    public func renameSpeaker(id: UUID, to name: String) {
        try? speakerProfileStore.rename(id: id, to: name)
        speakerProfiles = speakerProfileStore.profiles
        labelDisplayNames = speakerProfileStore.labelDisplayNames
    }

    public func deleteSpeaker(id: UUID) {
        try? speakerProfileStore.delete(id: id)
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
        try? speakerProfileStore.addTag(tag, to: profileId)
        speakerProfiles = speakerProfileStore.profiles
    }

    public func removeTag(_ tag: String, from profileId: UUID) {
        try? speakerProfileStore.removeTag(tag, from: profileId)
        speakerProfiles = speakerProfileStore.profiles
    }

    public func addParticipantsByTag(_ tag: String) {
        let taggedProfiles = speakerProfileStore.profiles(withTag: tag)
        for profile in taggedProfiles {
            addParticipantFromProfile(profile.id)
        }
    }

    // MARK: - Meeting Participants

    public func addParticipantFromProfile(_ profileId: UUID) {
        guard let profile = speakerProfileStore.profiles.first(where: { $0.id == profileId }),
              !meetingParticipants.contains(where: { $0.speakerProfileId == profileId })
        else { return }
        let label = LabelUtils.nextAvailableLabel(
            usedLabels: Set(meetingParticipants.map { $0.assignedLabel })
        )
        meetingParticipants.append(MeetingParticipant(
            speakerProfileId: profileId,
            assignedLabel: label,
            displayName: profile.displayName ?? profile.label
        ))
    }

    public func addNewParticipant(displayName: String) {
        let label = LabelUtils.nextAvailableLabel(
            usedLabels: Set(meetingParticipants.map { $0.assignedLabel })
        )
        meetingParticipants.append(MeetingParticipant(
            speakerProfileId: nil,
            assignedLabel: label,
            displayName: displayName
        ))
        labelDisplayNames[label] = displayName
        sessionRenamedLabels.insert(label)
    }

    public func removeParticipant(id: String) {
        meetingParticipants.removeAll { $0.id == id }
    }

    public func clearParticipants() {
        meetingParticipants = []
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
        if params.diarizationMode == .manual && !meetingParticipants.isEmpty {
            participantProfiles = meetingParticipants.compactMap { participant in
                guard let profileId = participant.speakerProfileId,
                      let stored = speakerProfileStore.profiles.first(where: { $0.id == profileId })
                else { return nil }
                return (participant.assignedLabel, stored.embedding)
            }
        } else {
            participantProfiles = nil
        }

        let sessionPrefix = self.previousSessionText
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
                        if sessionPrefix.isEmpty {
                            self.confirmedText = state.confirmedText
                        } else if state.confirmedText.isEmpty {
                            self.confirmedText = sessionPrefix
                        } else {
                            self.confirmedText = sessionPrefix + "\n" + state.confirmedText
                        }
                        self.unconfirmedText = state.unconfirmedText
                        let newSegments: [ConfirmedSegment]
                        if sessionSegments.isEmpty {
                            newSegments = state.confirmedSegments
                        } else if state.confirmedSegments.isEmpty {
                            newSegments = sessionSegments
                        } else {
                            newSegments = sessionSegments + state.confirmedSegments
                        }
                        self.confirmedSegments = Self.mergePreservingUserCorrections(
                            existing: self.confirmedSegments,
                            incoming: newSegments
                        )
                        let fileText = self.resolvedFileText()
                        self.fileWriter.updateText(fileText)
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
            if !confirmedText.isEmpty {
                confirmedText += "\n"
            }
            confirmedText += unconfirmedText
            unconfirmedText = ""
        }
        previousSessionText = confirmedText
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
        fileWriter.updateText(resolvedFileText())
        let pendingNames = self.labelDisplayNames
        let renamedLabels = self.sessionRenamedLabels
        let participants = self.meetingParticipants
        Task {
            await service.stopTranscription()
            // Apply display names only for labels explicitly renamed during this session
            for (label, name) in pendingNames {
                guard renamedLabels.contains(label) else { continue }
                if let profile = self.speakerProfileStore.profiles.first(where: { $0.label == label }) {
                    try? self.speakerProfileStore.rename(id: profile.id, to: name)
                }
            }
            // Apply display names from new participants (no embedding yet) to newly created profiles
            for participant in participants where participant.speakerProfileId == nil {
                if let newProfile = self.speakerProfileStore.profiles.first(where: {
                    $0.label == participant.assignedLabel && ($0.displayName == nil || $0.displayName!.isEmpty)
                }) {
                    try? self.speakerProfileStore.rename(id: newProfile.id, to: participant.displayName)
                }
            }
            self.speakerProfiles = self.speakerProfileStore.profiles
            self.labelDisplayNames = self.speakerProfileStore.labelDisplayNames
        }
    }

    private func resolvedFileText() -> String {
        guard !confirmedSegments.isEmpty, !labelDisplayNames.isEmpty else {
            return confirmedText
        }
        return TranscriptionUtils.joinSegments(
            confirmedSegments,
            language: currentLanguage.rawValue,
            silenceThreshold: parametersStore.parameters.silenceLineBreakThreshold,
            labelDisplayNames: labelDisplayNames
        )
    }
}
