import SwiftUI
import AppKit

public struct SettingsView: View {
    @ObservedObject private var store = ParametersStore.shared
    @ObservedObject var viewModel: TranscriptionViewModel

    public init(viewModel: TranscriptionViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        TabView {
            TranscriptionSettingsTab(store: store, viewModel: viewModel)
                .tabItem {
                    Label("Transcription", systemImage: "waveform")
                }
            SpeakersSettingsTab(store: store, viewModel: viewModel)
                .tabItem {
                    Label("Speakers", systemImage: "person.2")
                }
            OutputSettingsTab()
                .tabItem {
                    Label("Output", systemImage: "folder")
                }
        }
        .frame(minWidth: 520, maxWidth: 520, minHeight: 500, maxHeight: 800)
    }
}

// MARK: - Transcription Settings

private struct TranscriptionSettingsTab: View {
    @ObservedObject var store: ParametersStore
    @ObservedObject var viewModel: TranscriptionViewModel

    var body: some View {
        Form {
            translationSection
            chunkSection
            decodingSection
            resetSection
        }
        .formStyle(.grouped)
    }

    private var translationSection: some View {
        Section("Translation") {
            Toggle("Enable Translation Panel", isOn: $viewModel.translationEnabled)
            if viewModel.translationEnabled {
                HStack {
                    Text("Direction")
                    Spacer()
                    Text("\(viewModel.currentLanguage.displayName) \u{2192} \(viewModel.translationTargetLanguage.displayName)")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var resetSection: some View {
        Section {
            Button("Reset to Defaults") {
                store.resetToDefaults()
            }
        }
    }

    private var chunkSection: some View {
        Section("Chunk Settings") {
            DoubleSliderRow(
                label: "Chunk Duration",
                value: $store.parameters.chunkDuration,
                range: 1.0...10.0,
                step: 0.5,
                format: "%.1f s"
            )

            DoubleSliderRow(
                label: "Silence Cutoff",
                value: $store.parameters.silenceCutoffDuration,
                range: 0.3...2.0,
                step: 0.1,
                format: "%.1f s"
            )

            SliderRow(
                label: "Silence Threshold",
                value: $store.parameters.silenceEnergyThreshold,
                range: 0.001...0.1,
                step: 0.001,
                format: "%.3f"
            )

            DoubleSliderRow(
                label: "Line Break Silence",
                value: $store.parameters.silenceLineBreakThreshold,
                range: 0.5...3.0,
                step: 0.1,
                format: "%.1f s"
            )
        }
    }

    private var decodingSection: some View {
        Section("Decoding") {
            SliderRow(
                label: "Temperature",
                value: $store.parameters.temperature,
                range: 0.0...1.0,
                step: 0.05,
                format: "%.2f"
            )

            StepperRow(
                label: "Temperature Fallback Count",
                value: $store.parameters.temperatureFallbackCount,
                range: 0...5
            )

            StepperRow(
                label: "Sample Length",
                value: $store.parameters.sampleLength,
                range: 1...224
            )

            StepperRow(
                label: "Concurrent Workers",
                value: $store.parameters.concurrentWorkerCount,
                range: 1...8
            )
        }
    }
}

// MARK: - Speakers Settings

private struct SpeakersSettingsTab: View {
    @ObservedObject var store: ParametersStore
    @ObservedObject var viewModel: TranscriptionViewModel

    @State private var showDeleteAllConfirmation = false
    @State private var showAddFromRegistered = false
    @State private var showNewParticipantAlert = false
    @State private var newParticipantName = ""
    @State private var searchText = ""
    @State private var selectedTag: String?

    var body: some View {
        Form {
            speakerDetectionSection
            if store.parameters.enableSpeakerDiarization {
                if store.parameters.diarizationMode == .manual || !viewModel.meetingParticipants.isEmpty {
                    meetingParticipantsSection
                }
                currentSessionSection
            }
            registeredSpeakersSection
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showAddFromRegistered) {
            AddFromRegisteredSheet(
                profiles: viewModel.speakerProfiles,
                existingParticipantIds: Set(viewModel.meetingParticipants.compactMap { $0.speakerProfileId }),
                onAdd: { profileId in
                    viewModel.addParticipantFromProfile(profileId)
                }
            )
        }
    }

    // MARK: - Speaker Detection

    private var speakerDetectionSection: some View {
        Section("Speaker Detection") {
            Toggle("Enable Speaker Diarization", isOn: $store.parameters.enableSpeakerDiarization)
            if store.parameters.enableSpeakerDiarization {
                Picker("Mode", selection: $store.parameters.diarizationMode) {
                    Text("Auto").tag(DiarizationMode.auto)
                    Text("Manual").tag(DiarizationMode.manual)
                }
                if store.parameters.diarizationMode == .auto {
                    Picker("Number of Speakers", selection: Binding(
                        get: { store.parameters.expectedSpeakerCount ?? 0 },
                        set: { store.parameters.expectedSpeakerCount = $0 == 0 ? nil : $0 }
                    )) {
                        Text("Auto").tag(0)
                        ForEach(2...5, id: \.self) { n in
                            Text("\(n)").tag(n)
                        }
                    }
                } else {
                    HStack {
                        Text("Number of Speakers")
                        Spacer()
                        Text("\(viewModel.meetingParticipants.count)")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Meeting Participants

    private var meetingParticipantsSection: some View {
        Section("Meeting Participants (\(viewModel.meetingParticipants.count))") {
            if store.parameters.diarizationMode == .manual && viewModel.meetingParticipants.isEmpty {
                Label("No participants set \u{2014} running in auto mode", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }
            ForEach(viewModel.meetingParticipants) { participant in
                HStack {
                    Text(participant.assignedLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 24)
                    Text(participant.displayName)
                    if participant.speakerProfileId != nil {
                        Text("Registered")
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.blue.opacity(0.15))
                            .foregroundStyle(.blue)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                    Spacer()
                    Button {
                        viewModel.removeParticipant(id: participant.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
            }
            HStack(spacing: 8) {
                Button("Add from Registered...") {
                    showAddFromRegistered = true
                }
                .disabled(viewModel.speakerProfiles.isEmpty)
                Button("New Person...") {
                    newParticipantName = ""
                    showNewParticipantAlert = true
                }
                if !viewModel.meetingParticipants.isEmpty {
                    Button("Clear All", role: .destructive) {
                        viewModel.clearParticipants()
                    }
                }
            }
            .alert("New Participant", isPresented: $showNewParticipantAlert) {
                TextField("Name", text: $newParticipantName)
                Button("Add") {
                    let name = newParticipantName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty {
                        viewModel.addNewParticipant(displayName: name)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Enter a name for the new participant:")
            }
        }
    }

    // MARK: - Current Session

    private var currentSessionSection: some View {
        Section("Current Session") {
            if viewModel.sessionSpeakers.isEmpty {
                Text("No speakers detected yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.sessionSpeakers) { speaker in
                    SessionSpeakerRow(
                        speaker: speaker,
                        onRename: { name in
                            viewModel.renameSessionSpeaker(label: speaker.label, displayName: name)
                        }
                    )
                    .id("\(speaker.label)-\(speaker.displayName ?? "")")
                }
            }
        }
    }

    // MARK: - Registered Speakers

    private var filteredProfiles: [StoredSpeakerProfile] {
        var result = viewModel.speakerProfiles
        if let tag = selectedTag {
            result = result.filter { $0.tags.contains(tag) }
        }
        if !searchText.isEmpty {
            result = result.filter {
                ($0.displayName ?? "").localizedCaseInsensitiveContains(searchText)
                || $0.label.localizedCaseInsensitiveContains(searchText)
                || $0.tags.contains { $0.localizedCaseInsensitiveContains(searchText) }
            }
        }
        return result
    }

    private var registeredSpeakersSection: some View {
        Section("Registered Speakers (\(viewModel.speakerProfiles.count))") {
            if viewModel.speakerProfiles.isEmpty {
                Text("No speakers registered yet.")
                    .foregroundStyle(.secondary)
            } else {
                TextField("Search speakers...", text: $searchText)
                    .textFieldStyle(.roundedBorder)

                if !viewModel.allTags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            TagFilterPill(label: "All", isSelected: selectedTag == nil) {
                                selectedTag = nil
                            }
                            ForEach(viewModel.allTags, id: \.self) { tag in
                                TagFilterPill(label: tag, isSelected: selectedTag == tag) {
                                    selectedTag = selectedTag == tag ? nil : tag
                                }
                            }
                            if let tag = selectedTag, store.parameters.diarizationMode == .manual {
                                Button("Add by Tag") {
                                    viewModel.addParticipantsByTag(tag)
                                }
                                .font(.caption)
                            }
                        }
                    }
                }

                ForEach(filteredProfiles, id: \.id) { profile in
                    SpeakerProfileRow(
                        profile: profile,
                        allTags: viewModel.allTags,
                        onRename: { name in
                            viewModel.renameSpeaker(id: profile.id, to: name)
                        },
                        onDelete: {
                            viewModel.deleteSpeaker(id: profile.id)
                        },
                        onAddTag: { tag in
                            viewModel.addTag(tag, to: profile.id)
                        },
                        onRemoveTag: { tag in
                            viewModel.removeTag(tag, from: profile.id)
                        }
                    )
                    .id("\(profile.id)-\(profile.displayName ?? "")-\(profile.tags.joined())")
                }
                Button("Delete All Profiles", role: .destructive) {
                    showDeleteAllConfirmation = true
                }
                .confirmationDialog(
                    "Delete all speaker profiles?",
                    isPresented: $showDeleteAllConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Delete All", role: .destructive) {
                        viewModel.deleteAllSpeakers()
                    }
                }
            }
        }
    }
}

// MARK: - Add from Registered Sheet

private struct AddFromRegisteredSheet: View {
    let profiles: [StoredSpeakerProfile]
    let existingParticipantIds: Set<UUID>
    let onAdd: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Add from Registered Speakers")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding()

            if profiles.isEmpty {
                Text("No registered speakers.")
                    .foregroundStyle(.secondary)
                    .padding()
            } else {
                List(profiles, id: \.id) { profile in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.displayName ?? profile.label)
                            Text("Speaker \(profile.label) · \(profile.sessionCount) sessions")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if existingParticipantIds.contains(profile.id) {
                            Text("Added")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Button("Add") {
                                onAdd(profile.id)
                            }
                        }
                    }
                }
            }
        }
        .frame(minWidth: 350, minHeight: 300)
    }
}

// MARK: - Output Settings

private struct OutputSettingsTab: View {
    @AppStorage("transcriptsDirectory") private var transcriptsDirectory: String = ""
    @AppStorage("isRecording") private var isRecording: Bool = false

    private var displayPath: String {
        let path = transcriptsDirectory.isEmpty
            ? TranscriptFileWriter.defaultDirectory.path
            : transcriptsDirectory
        return path.replacingOccurrences(
            of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
    }

    var body: some View {
        Form {
            Section("Transcript Output") {
                HStack {
                    Text("Output Folder")
                    Spacer()
                    Text(displayPath)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                HStack {
                    Button("Choose Folder...") {
                        chooseFolder()
                    }
                    .disabled(isRecording)
                    if !transcriptsDirectory.isEmpty {
                        Button("Reset to Default") {
                            transcriptsDirectory = ""
                        }
                        .disabled(isRecording)
                    }
                }
                if isRecording {
                    Text("Stop recording to change the output folder.")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }
            Section {
                Text("Transcripts are saved as **YYYY-MM-DD_HHmm_qt_transcript.md** with a **qt_transcript.md** symlink pointing to the latest file.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"
        panel.message = "Choose a folder for transcript output"
        if panel.runModal() == .OK, let url = panel.url {
            transcriptsDirectory = url.path
        }
    }
}

// MARK: - Session Speaker Row

private struct SessionSpeakerRow: View {
    let speaker: TranscriptionViewModel.SessionSpeakerInfo
    let onRename: (String) -> Void

    @State private var editingName: String

    init(speaker: TranscriptionViewModel.SessionSpeakerInfo, onRename: @escaping (String) -> Void) {
        self.speaker = speaker
        self.onRename = onRename
        self._editingName = State(initialValue: speaker.displayName ?? "")
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text("Speaker \(speaker.label)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if speaker.storedProfileId != nil {
                        Text("Registered")
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.blue.opacity(0.15))
                            .foregroundStyle(.blue)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                }
                TextField("Enter name...", text: $editingName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        onRename(editingName)
                    }
            }
            Spacer()
        }
    }
}

// MARK: - Speaker Profile Row

private struct SpeakerProfileRow: View {
    let profile: StoredSpeakerProfile
    let allTags: [String]
    let onRename: (String) -> Void
    let onDelete: () -> Void
    let onAddTag: (String) -> Void
    let onRemoveTag: (String) -> Void

    @State private var editingName: String
    @State private var showTagPopover = false
    @State private var newTagText = ""

    init(profile: StoredSpeakerProfile, allTags: [String] = [], onRename: @escaping (String) -> Void, onDelete: @escaping () -> Void, onAddTag: @escaping (String) -> Void = { _ in }, onRemoveTag: @escaping (String) -> Void = { _ in }) {
        self.profile = profile
        self.allTags = allTags
        self.onRename = onRename
        self.onDelete = onDelete
        self.onAddTag = onAddTag
        self.onRemoveTag = onRemoveTag
        self._editingName = State(initialValue: profile.displayName ?? "")
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    private var idPrefix: String {
        String(profile.id.uuidString.prefix(8).lowercased())
    }

    private var lastUsedText: String {
        Self.dateFormatter.string(from: profile.lastUsed)
    }

    private var suggestedTags: [String] {
        allTags.filter { !profile.tags.contains($0) }
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text("Speaker \(profile.label)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("#\(idPrefix)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text("\u{00B7}")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text("\(profile.sessionCount) sessions")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text("\u{00B7}")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text("Last: \(lastUsedText)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                TextField("Speaker \(profile.label)", text: $editingName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        onRename(editingName)
                    }
                HStack(spacing: 4) {
                    ForEach(profile.tags, id: \.self) { tag in
                        TagPill(tag: tag) { onRemoveTag(tag) }
                    }
                    Button {
                        newTagText = ""
                        showTagPopover = true
                    } label: {
                        Image(systemName: "plus.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .popover(isPresented: $showTagPopover) {
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("New tag...", text: $newTagText)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 150)
                                .onSubmit {
                                    let trimmed = newTagText.trimmingCharacters(in: .whitespacesAndNewlines)
                                    if !trimmed.isEmpty {
                                        onAddTag(trimmed)
                                        showTagPopover = false
                                    }
                                }
                            if !suggestedTags.isEmpty {
                                Text("Existing tags:")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                FlowLayout(spacing: 4) {
                                    ForEach(suggestedTags, id: \.self) { tag in
                                        Button(tag) {
                                            onAddTag(tag)
                                            showTagPopover = false
                                        }
                                        .font(.caption)
                                        .buttonStyle(.bordered)
                                    }
                                }
                            }
                        }
                        .padding(8)
                    }
                }
            }
            Spacer()
            Button(action: onDelete) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
    }
}

// MARK: - Tag UI

private struct TagPill: View {
    let tag: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            Text(tag)
                .font(.caption2)
            Button {
                onRemove()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8))
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(.secondary.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

private struct TagFilterPill: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(isSelected ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.1))
                .foregroundStyle(isSelected ? Color.accentColor : .primary)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        var height: CGFloat = 0
        for (i, row) in rows.enumerated() {
            let maxH = row.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
            height += maxH
            if i > 0 { height += spacing }
        }
        return CGSize(width: proposal.width ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            let maxH = row.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
            var x = bounds.minX
            for subview in row {
                let size = subview.sizeThatFits(.unspecified)
                subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += maxH + spacing
        }
    }

    private func computeRows(proposal: ProposedViewSize, subviews: Subviews) -> [[LayoutSubviews.Element]] {
        let maxWidth = proposal.width ?? .infinity
        var rows: [[LayoutSubviews.Element]] = [[]]
        var currentWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentWidth + size.width > maxWidth && !rows[rows.count - 1].isEmpty {
                rows.append([])
                currentWidth = 0
            }
            rows[rows.count - 1].append(subview)
            currentWidth += size.width + spacing
        }
        return rows
    }
}

// MARK: - Reusable Controls

private struct SliderRow: View {
    let label: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    let step: Float
    let format: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                Spacer()
                Text(String(format: format, value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(
                    get: { Double(value) },
                    set: { value = Float($0) }
                ),
                in: Double(range.lowerBound)...Double(range.upperBound),
                step: Double(step)
            )
        }
    }
}

private struct DoubleSliderRow: View {
    let label: String
    @Binding var value: TimeInterval
    let range: ClosedRange<Double>
    let step: Double
    let format: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                Spacer()
                Text(String(format: format, value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, step: step)
        }
    }
}

private struct StepperRow: View {
    let label: String
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        Stepper(value: $value, in: range) {
            HStack {
                Text(label)
                Spacer()
                Text("\(value)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }
}
