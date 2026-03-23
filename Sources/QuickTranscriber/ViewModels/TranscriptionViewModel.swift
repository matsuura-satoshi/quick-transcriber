import Foundation
import SwiftUI
import AppKit
import Combine

public enum SpeakerEntity: Equatable {
    case active(id: UUID)
    case registered(id: UUID)
}

public struct SpeakerMergeRequest: Equatable {
    public let sourceEntity: SpeakerEntity
    public let targetEntity: SpeakerEntity
    public let duplicateName: String
    public let sourceDisplayName: String
    public let targetDisplayName: String
}

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
    @Published public var preExistingProfileIds: Set<UUID> = []
    @Published public var showPostMeetingTagging: Bool = false
    @Published public var pendingMergeRequest: SpeakerMergeRequest?
    @Published public var translationEnabled: Bool = UserDefaults.standard.bool(forKey: "translationEnabled")
    public let translationService = TranslationService()

    public var silenceLineBreakThreshold: TimeInterval {
        parametersStore.parameters.silenceLineBreakThreshold
    }

    public var translationTargetLanguage: Language {
        currentLanguage == .english ? .japanese : .english
    }

    // MARK: - File Transcription State

    @Published var isTranscribingFile = false
    @Published var fileTranscriptionProgress: Double = 0.0
    @Published var showReplaceFileAlert = false
    @Published var fileTranscriptionError: String?
    var pendingFileURL: URL?
    var transcribingFileName: String?
    private var fileTranscriptionEngine: ChunkedWhisperEngine?

    // MARK: - Coordinator

    public let coordinator: SpeakerStateCoordinator

    private var service: TranscriptionService
    private let modelName: String
    internal let parametersStore: ParametersStore
    internal let speakerProfileStore: SpeakerProfileStore
    private let fileWriter: TranscriptFileWriter
    private var fileSessionActive: Bool = false
    private var previousSessionSegments: [ConfirmedSegment] = []
    private var cancellables: Set<AnyCancellable> = []
    private let sharedTranscriber: ChunkTranscriber
    private let sharedDiarizer: SpeakerDiarizer?

    // MARK: - Backward Compatibility (delegate to coordinator)

    public var speakerMenuOrder: [String] {
        get { coordinator.speakerMenuOrder }
        set { coordinator.speakerMenuOrder = newValue }
    }
    var trackerAliases: [String: UUID] {
        get { coordinator.trackerAliases }
        set { coordinator.trackerAliases = newValue }
    }
    var removedSpeakerIds: Set<UUID> {
        get { coordinator.removedSpeakerIds }
        set { coordinator.removedSpeakerIds = newValue }
    }
    var historicalSpeakerNames: [String: String] {
        get { coordinator.historicalSpeakerNames }
        set { coordinator.historicalSpeakerNames = newValue }
    }
    public var pendingProfileDeletions: Set<UUID> {
        get { coordinator.pendingProfileDeletions }
        set { coordinator.pendingProfileDeletions = newValue }
    }
    var recordingDiarizationMode: DiarizationMode {
        get { coordinator.recordingDiarizationMode }
        set { coordinator.recordingDiarizationMode = newValue }
    }

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
        self.coordinator = SpeakerStateCoordinator(
            profileStore: profileStore,
            embeddingHistoryStore: resolvedEmbeddingHistoryStore
        )
        // Always create diarizer so it's available when the user enables it at runtime.
        // The enableSpeakerDiarization parameter controls whether it's actually used.
        // Store transcriber and diarizer for reuse in file transcription engine.
        let resolvedDiarizer: SpeakerDiarizer? = diarizer ?? FluidAudioSpeakerDiarizer()
        let resolvedTranscriber: ChunkTranscriber = WhisperKitChunkTranscriber()
        self.sharedDiarizer = resolvedDiarizer
        self.sharedTranscriber = resolvedTranscriber
        let resolvedEngine = engine ?? ChunkedWhisperEngine(
            transcriber: resolvedTranscriber,
            diarizer: resolvedDiarizer,
            speakerProfileStore: profileStore,
            embeddingHistoryStore: resolvedEmbeddingHistoryStore
        )
        self.service = TranscriptionService(engine: resolvedEngine)
        self.modelName = modelName
        self.parametersStore = resolvedStore
        self.fileWriter = fileWriter ?? TranscriptFileWriter()
        coordinator.setService(self.service)

        // Bidirectional sync: when tests or external code sets activeSpeakers directly,
        // propagate to coordinator so availableSpeakers and other coordinator state stays consistent
        $activeSpeakers
            .sink { [weak self] newValue in
                guard let self, self.coordinator.activeSpeakers != newValue else { return }
                self.coordinator.activeSpeakers = newValue
                self.coordinator.updateSpeakerDisplayNames()
                self.speakerDisplayNames = self.coordinator.speakerDisplayNames
            }
            .store(in: &cancellables)

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

    // MARK: - Sync Helpers

    private func syncSpeakerState() {
        self.activeSpeakers = coordinator.activeSpeakers
        self.speakerDisplayNames = coordinator.speakerDisplayNames
    }

    private func syncProfiles() {
        self.speakerProfiles = coordinator.profileStore.profiles
    }

    // MARK: - Model Loading

    public func loadModel() async {
        modelState = .loading
        NSLog("[QuickTranscriber] \(Constants.Version.versionString) — Loading model: \(modelName)")
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
        guard !isTranscribingFile else { return }
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
        coordinator.reset()
        syncSpeakerState()
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

    public func resetFontSize() {
        fontSize = 15
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

    // MARK: - Active Speakers (Coordinator delegation)

    public var availableSpeakers: [SpeakerMenuItem] {
        coordinator.availableSpeakers
    }

    public var nextSpeakerPlaceholder: String {
        coordinator.nextSpeakerPlaceholder
    }

    public var activeProfileIds: Set<UUID> {
        coordinator.activeProfileIds
    }

    public func recordSpeakerSelection(_ idStr: String) {
        coordinator.recordSpeakerSelection(idStr)
    }

    // MARK: - Name Uniqueness & Merge

    public func checkNameUniqueness(newName: String, forEntity: SpeakerEntity) -> SpeakerMergeRequest? {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let selfId: UUID
        let selfLinkedProfileId: UUID?
        switch forEntity {
        case .active(let id):
            selfId = id
            selfLinkedProfileId = coordinator.activeSpeakers.first(where: { $0.id == id })?.speakerProfileId
        case .registered(let id):
            selfId = id
            selfLinkedProfileId = nil
        }

        // Check active speakers
        for speaker in coordinator.activeSpeakers {
            guard speaker.id != selfId else { continue }
            // Skip if this active speaker is the linked profile of self
            if let linkedId = selfLinkedProfileId, speaker.id == linkedId { continue }
            if let name = speaker.displayName, name.caseInsensitiveCompare(trimmed) == .orderedSame {
                let sourceDisplayName: String
                switch forEntity {
                case .active(let id):
                    sourceDisplayName = coordinator.activeSpeakers.first(where: { $0.id == id })?.displayName ?? ""
                case .registered(let id):
                    sourceDisplayName = speakerProfileStore.profiles.first(where: { $0.id == id })?.displayName ?? ""
                }
                return SpeakerMergeRequest(
                    sourceEntity: forEntity,
                    targetEntity: .active(id: speaker.id),
                    duplicateName: trimmed,
                    sourceDisplayName: sourceDisplayName,
                    targetDisplayName: speaker.displayName ?? ""
                )
            }
        }

        // Check registered profiles
        for profile in speakerProfileStore.profiles {
            guard profile.id != selfId else { continue }
            // Skip if self is active and linked to this profile
            if let linkedId = selfLinkedProfileId, profile.id == linkedId { continue }
            // Skip if this profile is already represented by an active speaker we checked above
            if coordinator.activeSpeakers.contains(where: { $0.speakerProfileId == profile.id || $0.id == profile.id }) { continue }
            if profile.displayName.caseInsensitiveCompare(trimmed) == .orderedSame {
                let sourceDisplayName: String
                switch forEntity {
                case .active(let id):
                    sourceDisplayName = coordinator.activeSpeakers.first(where: { $0.id == id })?.displayName ?? ""
                case .registered(let id):
                    sourceDisplayName = speakerProfileStore.profiles.first(where: { $0.id == id })?.displayName ?? ""
                }
                return SpeakerMergeRequest(
                    sourceEntity: forEntity,
                    targetEntity: .registered(id: profile.id),
                    duplicateName: trimmed,
                    sourceDisplayName: sourceDisplayName,
                    targetDisplayName: profile.displayName
                )
            }
        }

        return nil
    }

    public func tryRenameActiveSpeaker(id: UUID, displayName: String) {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let mergeRequest = checkNameUniqueness(newName: trimmed, forEntity: .active(id: id)) {
            pendingMergeRequest = mergeRequest
        } else {
            renameActiveSpeaker(id: id, displayName: trimmed)
        }
    }

    public func tryRenameSpeaker(id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let mergeRequest = checkNameUniqueness(newName: trimmed, forEntity: .registered(id: id)) {
            pendingMergeRequest = mergeRequest
        } else {
            renameSpeaker(id: id, to: trimmed)
        }
    }

    public func executeMerge(_ request: SpeakerMergeRequest) {
        pendingMergeRequest = nil
        coordinator.executeMerge(request, segments: &confirmedSegments, isRecording: isRecording)
        syncSpeakerState()
        syncProfiles()
        regenerateText()
        translationService.syncSpeakerMetadata(from: confirmedSegments)
    }

    public func cancelMerge() {
        pendingMergeRequest = nil
    }

    public func renameActiveSpeaker(id: UUID, displayName: String) {
        coordinator.renameActiveSpeaker(id: id, displayName: displayName)
        syncSpeakerState()
        syncProfiles()
        regenerateText()
    }

    // MARK: - Speaker Reassignment

    public func splitSegment(at index: Int, offset: Int) {
        coordinator.splitSegment(at: index, offset: offset, segments: &confirmedSegments)
        translationService.splitSegment(at: index)
    }

    public func reassignSpeakerForBlock(segmentIndex: Int, newSpeaker: String) {
        coordinator.reassignSpeakerForBlock(segmentIndex: segmentIndex, newSpeaker: newSpeaker, segments: &confirmedSegments)
        syncSpeakerState()
        regenerateText()
        translationService.syncSpeakerMetadata(from: confirmedSegments)
    }

    public func reassignSpeakerForSelection(
        selectionRange: NSRange,
        newSpeaker: String,
        segmentMap: SegmentCharacterMap
    ) {
        coordinator.reassignSpeakerForSelection(
            selectionRange: selectionRange,
            newSpeaker: newSpeaker,
            segmentMap: segmentMap,
            segments: &confirmedSegments
        ) { [weak self] index in
            self?.translationService.splitSegment(at: index)
        }
        syncSpeakerState()
        regenerateText()
        translationService.syncSpeakerMetadata(from: confirmedSegments)
    }

    public func regenerateText() {
        fileWriter.updateText(confirmedText)
    }

    // MARK: - Speaker Profile Management

    public func renameSpeaker(id: UUID, to name: String) {
        coordinator.renameSpeaker(id: id, to: name)
        syncProfiles()
    }

    public func setLocked(id: UUID, locked: Bool) {
        coordinator.setLocked(id: id, locked: locked)
        syncProfiles()
    }

    public func deleteSpeaker(id: UUID) {
        coordinator.deleteSpeaker(id: id, isRecording: isRecording)
        syncSpeakerState()
        if !isRecording {
            syncProfiles()
        }
    }

    public func deleteAllSpeakers() {
        coordinator.deleteAllSpeakers()
        syncSpeakerState()
        speakerProfiles = []
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
        syncProfiles()
    }

    public func removeTag(_ tag: String, from profileId: UUID) {
        do {
            try speakerProfileStore.removeTag(tag, from: profileId)
        } catch {
            NSLog("[QuickTranscriber] Failed to remove tag '\(tag)' from profile \(profileId): \(error)")
        }
        syncProfiles()
    }

    public func addManualSpeakersByTag(_ tag: String) {
        coordinator.addManualSpeakersByTag(tag)
        syncSpeakerState()
    }

    public func addManualSpeakers(profileIds: [UUID]) {
        coordinator.addManualSpeakers(profileIds: profileIds)
        syncSpeakerState()
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
        coordinator.addManualSpeaker(fromProfile: profileId)
        syncSpeakerState()
    }

    public func addManualSpeaker(displayName: String) {
        coordinator.addManualSpeaker(displayName: displayName)
        syncSpeakerState()
    }

    public func addAndReassignBlock(profileId: UUID, segmentIndex: Int) {
        addManualSpeaker(fromProfile: profileId)
        guard let speaker = coordinator.activeSpeakers.last(where: { $0.speakerProfileId == profileId }) else { return }
        reassignSpeakerForBlock(segmentIndex: segmentIndex, newSpeaker: speaker.id.uuidString)
    }

    public func addAndReassignSelection(profileId: UUID, selectionRange: NSRange, segmentMap: SegmentCharacterMap) {
        addManualSpeaker(fromProfile: profileId)
        guard let speaker = coordinator.activeSpeakers.last(where: { $0.speakerProfileId == profileId }) else { return }
        reassignSpeakerForSelection(selectionRange: selectionRange, newSpeaker: speaker.id.uuidString, segmentMap: segmentMap)
    }

    public func removeActiveSpeaker(id: UUID) {
        coordinator.removeActiveSpeaker(id: id)
        syncSpeakerState()
    }

    public func deactivateSpeaker(profileId: UUID) {
        coordinator.deactivateSpeaker(profileId: profileId)
        syncSpeakerState()
    }

    public func bulkActivateProfiles(ids: [UUID]) {
        coordinator.bulkActivateProfiles(ids: ids)
        syncSpeakerState()
    }

    public func bulkDeactivateProfiles(ids: Set<UUID>) {
        coordinator.bulkDeactivateProfiles(ids: ids)
        syncSpeakerState()
    }

    public func clearActiveSpeakers(source: ActiveSpeaker.Source? = nil) {
        coordinator.clearActiveSpeakers(source: source)
        syncSpeakerState()
    }

    public func deleteSpeakers(ids: Set<UUID>) {
        coordinator.deleteSpeakers(ids: ids, isRecording: isRecording)
        syncSpeakerState()
        if !isRecording {
            syncProfiles()
        }
    }

    // MARK: - Private

    func snapshotDiarizationMode() {
        coordinator.snapshotDiarizationMode(parametersStore.parameters.diarizationMode)
    }

    func restartRecording() {
        saveUnconfirmedText()
        isRecording = false
        let displayNames = self.speakerDisplayNames
        Task {
            await service.stopTranscription(speakerDisplayNames: displayNames)
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
        var params = parametersStore.parameters
        coordinator.snapshotDiarizationMode(params.diarizationMode)
        NSLog("[QuickTranscriber] Starting recording, language: \(currentLanguage.rawValue), params: \(params)")

        // Generate shared date prefix for transcript and recording files
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmm"
        let datePrefix = formatter.string(from: Date())

        if !fileSessionActive {
            fileWriter.startSession(language: currentLanguage, initialText: confirmedText, datePrefix: datePrefix)
            fileSessionActive = true
        } else if fileWriter.hasDirectoryChanged {
            fileWriter.endSession()
            fileWriter.startSession(language: currentLanguage, initialText: confirmedText, datePrefix: datePrefix)
        }

        // Resolve participant profiles for manual mode
        let participantProfiles: [(speakerId: UUID, embedding: [Float])]?
        if params.diarizationMode == .manual {
            let speakersWithProfiles = coordinator.activeSpeakers.compactMap { speaker -> (speakerId: UUID, embedding: [Float])? in
                guard let profileId = speaker.speakerProfileId,
                      let stored = speakerProfileStore.profiles.first(where: { $0.id == profileId })
                else { return nil }
                return (speakerId: stored.id, embedding: stored.embedding)
            }
            participantProfiles = speakersWithProfiles
            params.expectedSpeakerCount = coordinator.activeSpeakers.count
        } else {
            participantProfiles = nil
        }

        // Resolve audio recording settings
        let audioRecordingEnabled = UserDefaults.standard.bool(forKey: "audioRecordingEnabled")
        let audioRecordingDirectory: URL? = audioRecordingEnabled ? fileWriter.resolvedDirectory : nil
        let audioRecordingDatePrefix: String? = audioRecordingEnabled ? datePrefix : nil

        let sessionSegments = self.previousSessionSegments
        Task {
            do {
                try await service.startTranscription(
                    language: currentLanguage.rawValue,
                    parameters: params,
                    participantProfiles: participantProfiles,
                    audioRecordingDirectory: audioRecordingDirectory,
                    audioRecordingDatePrefix: audioRecordingDatePrefix
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
                        // Snapshot speakers before merge for change detection
                        let oldSpeakers = self.confirmedSegments.map { $0.speaker }

                        self.confirmedSegments = Self.mergePreservingUserCorrections(
                            existing: self.confirmedSegments,
                            incoming: newSegments
                        )

                        // Detect retroactive speaker changes and propagate to translation
                        let existingCount = min(oldSpeakers.count, self.confirmedSegments.count)
                        var speakerChanged = false
                        for i in 0..<existingCount {
                            if oldSpeakers[i] != self.confirmedSegments[i].speaker {
                                speakerChanged = true
                                break
                            }
                        }
                        if speakerChanged {
                            self.translationService.syncSpeakerMetadata(from: self.confirmedSegments)
                        }

                        // Auto-detect new speakers from segments
                        for segment in stateSegments {
                            if let speakerId = segment.speaker {
                                self.coordinator.addAutoDetectedSpeaker(speakerId: speakerId, embedding: segment.speakerEmbedding)
                            }
                        }

                        self.syncSpeakerState()
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
            let _ = self.coordinator.linkActiveSpeakersToProfiles(segments: self.confirmedSegments)
            self.syncSpeakerState()
            self.syncProfiles()
            self.coordinator.flushPendingDeletions()
            self.syncProfiles()
            self.coordinator.verifyInvariants(segments: self.confirmedSegments)
            if UserDefaults.standard.bool(forKey: "showPostMeetingSheet")
                && !self.coordinator.activeSpeakers.isEmpty {
                self.showPostMeetingTagging = true
            }
        }
    }

    // MARK: - File Transcription

    func transcribeFile(_ url: URL) {
        guard modelState == .ready else {
            NSLog("[QuickTranscriber] Cannot transcribe file: model not ready")
            return
        }
        guard !isTranscribingFile else {
            NSLog("[QuickTranscriber] Already transcribing a file")
            return
        }
        guard !isRecording else {
            NSLog("[QuickTranscriber] Cannot transcribe file during recording")
            return
        }

        // If there's existing text, show confirmation dialog
        if !confirmedText.isEmpty {
            pendingFileURL = url
            showReplaceFileAlert = true
            return
        }

        startFileTranscription(url)
    }

    func confirmReplaceAndTranscribe() {
        guard let url = pendingFileURL else { return }
        pendingFileURL = nil
        startFileTranscription(url)
    }

    private func startFileTranscription(_ url: URL) {
        Task {
            await beginFileTranscription(url)
        }
    }

    private func beginFileTranscription(_ url: URL) async {
        clearText()
        isTranscribingFile = true
        fileTranscriptionProgress = 0.0
        transcribingFileName = url.lastPathComponent

        let fileSource = FileAudioSource(fileURL: url)
        fileSource.onProgress = { [weak self] progress in
            Task { @MainActor [weak self] in
                self?.fileTranscriptionProgress = progress
            }
        }
        fileSource.onComplete = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.finishFileTranscription()
            }
        }

        // Create separate engine with shared transcriber and diarizer
        let fileEngine = ChunkedWhisperEngine(
            audioCaptureService: fileSource,
            transcriber: sharedTranscriber,
            diarizer: sharedDiarizer,
            speakerProfileStore: speakerProfileStore,
            embeddingHistoryStore: coordinator.embeddingHistoryStore
        )
        self.fileTranscriptionEngine = fileEngine

        // Build accuracy-optimized parameters
        var params = parametersStore.parameters
        params.chunkDuration = Constants.FileTranscription.chunkDuration
        params.silenceCutoffDuration = Constants.FileTranscription.endOfUtteranceSilence
        params.temperatureFallbackCount = Constants.FileTranscription.temperatureFallbackCount

        // Start file writer
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmm"
        let datePrefix = formatter.string(from: Date())
        if !fileSessionActive {
            fileWriter.startSession(language: currentLanguage, initialText: "", datePrefix: datePrefix)
            fileSessionActive = true
        }

        NSLog("[QuickTranscriber] Starting file transcription: %@", url.lastPathComponent)

        do {
            try await fileEngine.startStreaming(
                language: currentLanguage.rawValue,
                parameters: params,
                participantProfiles: nil,
                audioRecordingDirectory: nil,
                audioRecordingDatePrefix: nil
            ) { [weak self] state in
                Task { @MainActor [weak self] in
                    guard let self, self.isTranscribingFile else { return }
                    self.unconfirmedText = state.unconfirmedText
                    var stateSegments = state.confirmedSegments
                    if stateSegments.isEmpty && !state.confirmedText.isEmpty {
                        stateSegments = [ConfirmedSegment(text: state.confirmedText)]
                    }
                    self.confirmedSegments = Self.mergePreservingUserCorrections(
                        existing: self.confirmedSegments,
                        incoming: stateSegments
                    )
                    // Auto-detect speakers (same pattern as startRecording)
                    for segment in stateSegments {
                        if let speakerId = segment.speaker {
                            self.coordinator.addAutoDetectedSpeaker(
                                speakerId: speakerId,
                                embedding: segment.speakerEmbedding
                            )
                        }
                    }
                    self.syncSpeakerState()
                    self.fileWriter.updateText(self.confirmedText)
                }
            }
        } catch {
            NSLog("[QuickTranscriber] File transcription error: %@", error.localizedDescription)
            fileTranscriptionError = error.localizedDescription
            isTranscribingFile = false
            fileTranscriptionEngine = nil
            transcribingFileName = nil
        }
    }

    private func finishFileTranscription() async {
        guard let engine = fileTranscriptionEngine else { return }
        engine.drainOnStop = true
        await engine.stopStreaming(speakerDisplayNames: speakerDisplayNames)
        fileTranscriptionEngine = nil
        isTranscribingFile = false
        fileTranscriptionProgress = 1.0
        transcribingFileName = nil
        NSLog("[QuickTranscriber] File transcription complete: %d segments", confirmedSegments.count)
    }

    func cancelFileTranscription() {
        guard let engine = fileTranscriptionEngine else { return }
        Task {
            // Empty display names → skips profile merge via nil-guard in stopStreaming
            await engine.stopStreaming(speakerDisplayNames: [:])
            fileTranscriptionEngine = nil
            clearText()
            isTranscribingFile = false
            fileTranscriptionProgress = 0.0
            transcribingFileName = nil
            NSLog("[QuickTranscriber] File transcription cancelled")
        }
    }

    func addAutoDetectedSpeaker(speakerId: String, embedding: [Float]?) {
        coordinator.addAutoDetectedSpeaker(speakerId: speakerId, embedding: embedding)
        syncSpeakerState()
    }

    func flushPendingDeletions() {
        coordinator.flushPendingDeletions()
        syncProfiles()
    }

    func linkActiveSpeakersToProfiles() {
        let _ = coordinator.linkActiveSpeakersToProfiles(segments: confirmedSegments)
        syncSpeakerState()
        syncProfiles()
    }
}
