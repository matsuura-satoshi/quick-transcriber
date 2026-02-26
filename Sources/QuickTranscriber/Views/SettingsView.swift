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
        .frame(minWidth: 520, maxWidth: 520, minHeight: 500, maxHeight: 5000)
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

    @State private var showNewSpeakerAlert = false
    @State private var newSpeakerName = ""
    @State private var searchText = ""
    @State private var selectedTag: String?
    @State private var showBulkDeleteConfirmation = false

    var body: some View {
        Form {
            speakerDetectionSection
            if store.parameters.enableSpeakerDiarization {
                activeSpeakersSection
            }
            registeredSpeakersSection
        }
        .formStyle(.grouped)
        .alert(
            "Merge Speakers?",
            isPresented: Binding(
                get: { viewModel.pendingMergeRequest != nil },
                set: { if !$0 { viewModel.cancelMerge() } }
            )
        ) {
            Button("Merge") {
                if let request = viewModel.pendingMergeRequest {
                    viewModel.executeMerge(request)
                }
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {
                viewModel.cancelMerge()
            }
        } message: {
            if let request = viewModel.pendingMergeRequest {
                Text("Merge \"\(request.sourceDisplayName)\" into \"\(request.targetDisplayName)\"? All segments will be combined.")
            }
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
                        Text("\(viewModel.activeSpeakers.count)")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Active Speakers (unified section)

    private var activeSpeakersSection: some View {
        Section("Active Speakers (\(viewModel.activeSpeakers.count))") {
            if viewModel.activeSpeakers.isEmpty {
                if store.parameters.diarizationMode == .manual {
                    Label("No speakers added \u{2014} running in auto mode", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.callout)
                } else {
                    Text("No speakers detected yet.")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(viewModel.activeSpeakers) { speaker in
                ActiveSpeakerRow(
                    speaker: speaker,
                    onRename: { name in
                        viewModel.tryRenameActiveSpeaker(id: speaker.id, displayName: name)
                    },
                    onRemove: {
                        viewModel.removeActiveSpeaker(id: speaker.id)
                    }
                )
            }
            Button("New Speaker...") {
                newSpeakerName = ""
                showNewSpeakerAlert = true
            }
            .alert("New Speaker", isPresented: $showNewSpeakerAlert) {
                TextField(viewModel.nextSpeakerPlaceholder, text: $newSpeakerName)
                Button("Add") {
                    let name = newSpeakerName.trimmingCharacters(in: .whitespacesAndNewlines)
                    viewModel.addManualSpeaker(displayName: name)
                    newSpeakerName = ""
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Enter a name for the new speaker:")
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
                $0.displayName.localizedCaseInsensitiveContains(searchText)
                || $0.tags.contains { $0.localizedCaseInsensitiveContains(searchText) }
            }
        }
        return result
    }

    private var filteredProfileIds: Set<UUID> {
        Set(filteredProfiles.map { $0.id })
    }

    private var allFilteredAreActive: Bool {
        let ids = filteredProfileIds
        guard !ids.isEmpty else { return false }
        return ids.isSubset(of: viewModel.activeProfileIds)
    }

    @ViewBuilder
    private var bulkActionButtons: some View {
        HStack(spacing: 8) {
            if allFilteredAreActive {
                Button("Deactivate (\(filteredProfiles.count))") {
                    viewModel.bulkDeactivateProfiles(ids: filteredProfileIds)
                }
                .disabled(filteredProfiles.isEmpty || !store.parameters.enableSpeakerDiarization)
            } else {
                Button("Activate (\(filteredProfiles.count))") {
                    viewModel.bulkActivateProfiles(ids: filteredProfiles.map { $0.id })
                }
                .disabled(filteredProfiles.isEmpty || !store.parameters.enableSpeakerDiarization)
            }
            Button("Delete (\(filteredProfiles.count))...", role: .destructive) {
                showBulkDeleteConfirmation = true
            }
            .disabled(filteredProfiles.isEmpty)
            .confirmationDialog(
                "Delete \(filteredProfiles.count) speaker profile(s)?",
                isPresented: $showBulkDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete \(filteredProfiles.count) Profile(s)", role: .destructive) {
                    viewModel.deleteSpeakers(ids: filteredProfileIds)
                }
            }
        }
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
                        }
                    }
                }

                bulkActionButtons

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(filteredProfiles, id: \.id) { profile in
                        DisclosureGroup {
                            SpeakerProfileDetailView(
                                profile: profile,
                                allTags: viewModel.allTags,
                                onRename: { name in viewModel.tryRenameSpeaker(id: profile.id, to: name) },
                                onDelete: { viewModel.deleteSpeaker(id: profile.id) },
                                onAddTag: { tag in viewModel.addTag(tag, to: profile.id) },
                                onRemoveTag: { tag in viewModel.removeTag(tag, from: profile.id) },
                                onSetLocked: { locked in viewModel.setLocked(id: profile.id, locked: locked) }
                            )
                        } label: {
                            SpeakerProfileSummaryView(
                                profile: profile,
                                isActive: viewModel.activeProfileIds.contains(profile.id),
                                isDiarizationEnabled: store.parameters.enableSpeakerDiarization,
                                onToggleActive: { newValue in
                                    if newValue {
                                        viewModel.addManualSpeaker(fromProfile: profile.id)
                                    } else {
                                        viewModel.deactivateSpeaker(profileId: profile.id)
                                    }
                                }
                            )
                        }
                        Divider()
                    }
                }
            }
        }
    }
}

// MARK: - Active Speaker Row

private struct ActiveSpeakerRow: View {
    let speaker: ActiveSpeaker
    let onRename: (String) -> Void
    let onRemove: () -> Void

    @State private var editingName: String

    init(speaker: ActiveSpeaker, onRename: @escaping (String) -> Void, onRemove: @escaping () -> Void) {
        self.speaker = speaker
        self.onRename = onRename
        self.onRemove = onRemove
        self._editingName = State(initialValue: speaker.displayName ?? "")
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(speaker.displayName ?? "Speaker")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    sourceBadge
                    if speaker.speakerProfileId != nil {
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
                        let trimmed = editingName.trimmingCharacters(in: .whitespacesAndNewlines)
                        if trimmed.isEmpty {
                            editingName = speaker.displayName ?? ""
                        } else {
                            onRename(trimmed)
                        }
                    }
            }
            Spacer()
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
    }

    @ViewBuilder
    private var sourceBadge: some View {
        switch speaker.source {
        case .manual:
            Text("Manual")
                .font(.caption2)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(.green.opacity(0.15))
                .foregroundStyle(.green)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        case .autoDetected:
            Text("Auto")
                .font(.caption2)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(.orange.opacity(0.15))
                .foregroundStyle(.orange)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        }
    }
}

// MARK: - Output Settings

private struct OutputSettingsTab: View {
    @AppStorage("transcriptsDirectory") private var transcriptsDirectory: String = ""
    @AppStorage("isRecording") private var isRecording: Bool = false
    @AppStorage("showPostMeetingSheet") private var showPostMeetingSheet: Bool = true

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
            Section("After Recording") {
                Toggle("Show tag sheet after stopping recording", isOn: $showPostMeetingSheet)
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

// MARK: - Speaker Profile Summary (DisclosureGroup label)

private struct SpeakerProfileSummaryView: View {
    let profile: StoredSpeakerProfile
    let isActive: Bool
    let isDiarizationEnabled: Bool
    let onToggleActive: (Bool) -> Void

    var body: some View {
        HStack(spacing: 6) {
            if profile.isLocked {
                Image(systemName: "lock.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(profile.displayName)
                .lineLimit(1)
            ForEach(profile.tags, id: \.self) { tag in
                Text(tag)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.secondary.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            Spacer()
            if isDiarizationEnabled {
                Toggle("", isOn: Binding(
                    get: { isActive },
                    set: { onToggleActive($0) }
                ))
                .toggleStyle(.checkbox)
                .labelsHidden()
            }
        }
    }
}

// MARK: - Speaker Profile Detail (DisclosureGroup content)

private struct SpeakerProfileDetailView: View {
    let profile: StoredSpeakerProfile
    let allTags: [String]
    let onRename: (String) -> Void
    let onDelete: () -> Void
    let onAddTag: (String) -> Void
    let onRemoveTag: (String) -> Void
    let onSetLocked: (Bool) -> Void

    @State private var editingName: String
    @State private var showTagPopover = false
    @State private var newTagText = ""

    init(profile: StoredSpeakerProfile, allTags: [String],
         onRename: @escaping (String) -> Void,
         onDelete: @escaping () -> Void,
         onAddTag: @escaping (String) -> Void,
         onRemoveTag: @escaping (String) -> Void,
         onSetLocked: @escaping (Bool) -> Void) {
        self.profile = profile
        self.allTags = allTags
        self.onRename = onRename
        self.onDelete = onDelete
        self.onAddTag = onAddTag
        self.onRemoveTag = onRemoveTag
        self.onSetLocked = onSetLocked
        self._editingName = State(initialValue: profile.displayName)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    private var suggestedTags: [String] {
        allTags.filter { !profile.tags.contains($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Name editing
            HStack {
                Text("Name")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Display name...", text: $editingName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { onRename(editingName) }
            }

            // Session info
            HStack(spacing: 4) {
                Text("\(profile.sessionCount) sessions")
                Text("\u{00B7}")
                Text("Last: \(Self.dateFormatter.string(from: profile.lastUsed))")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)

            // Tag editing
            HStack(spacing: 4) {
                Text("Tags")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

            // Lock toggle
            HStack {
                Toggle("Lock", isOn: Binding(
                    get: { profile.isLocked },
                    set: { onSetLocked($0) }
                ))
                .font(.caption)
            }

            // Delete button
            HStack {
                Spacer()
                Button("Delete Profile", role: .destructive) {
                    onDelete()
                }
                .font(.caption)
            }
        }
        .padding(.leading, 4)
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

struct TagFilterPill: View {
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

struct FlowLayout: Layout {
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
