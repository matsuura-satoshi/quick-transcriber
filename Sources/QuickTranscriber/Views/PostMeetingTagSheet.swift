import SwiftUI

struct PostMeetingTagSheet: View {
    let activeSpeakers: [ActiveSpeaker]
    let allTags: [String]
    let onApply: (String, [UUID]) -> Void
    let onSkip: () -> Void

    @State private var tag: String = ""
    @State private var selectedSpeakerIds: Set<UUID>

    init(
        activeSpeakers: [ActiveSpeaker],
        allTags: [String],
        onApply: @escaping (String, [UUID]) -> Void,
        onSkip: @escaping () -> Void
    ) {
        self.activeSpeakers = activeSpeakers
        self.allTags = allTags
        self.onApply = onApply
        self.onSkip = onSkip
        self._selectedSpeakerIds = State(
            initialValue: Set(activeSpeakers.map { $0.id })
        )
    }

    private var selectedProfileIds: [UUID] {
        activeSpeakers
            .filter { selectedSpeakerIds.contains($0.id) }
            .compactMap { $0.speakerProfileId }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tag Session Speakers")
                .font(.headline)

            Text("\(activeSpeakers.count) speakers in this session:")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            speakerList

            Divider()

            tagInput

            if !allTags.isEmpty {
                tagSuggestions
            }

            actionButtons
        }
        .padding()
        .frame(minWidth: 380, maxWidth: 380, minHeight: 200)
    }

    private var speakerList: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(activeSpeakers) { speaker in
                HStack {
                    Toggle(isOn: Binding(
                        get: { selectedSpeakerIds.contains(speaker.id) },
                        set: { isOn in
                            if isOn {
                                selectedSpeakerIds.insert(speaker.id)
                            } else {
                                selectedSpeakerIds.remove(speaker.id)
                            }
                        }
                    )) {
                        HStack(spacing: 6) {
                            Text(speaker.displayName ?? "Speaker")
                            if speaker.speakerProfileId == nil {
                                Text("new")
                                    .font(.caption2)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(.blue.opacity(0.15))
                                    .foregroundStyle(.blue)
                                    .clipShape(RoundedRectangle(cornerRadius: 3))
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
        }
        }
        .frame(maxHeight: 200)
    }

    private var tagInput: some View {
        HStack {
            Text("Tag:")
            TextField("Enter tag name", text: $tag)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var tagSuggestions: some View {
        FlowLayout(spacing: 6) {
            ForEach(allTags, id: \.self) { existingTag in
                Button(existingTag) {
                    tag = existingTag
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private var actionButtons: some View {
        HStack {
            Button("Apply") {
                onApply(tag, selectedProfileIds)
            }
            .disabled(tag.trimmingCharacters(in: .whitespaces).isEmpty)
            .keyboardShortcut(.defaultAction)

            Spacer()

            Button("Skip") {
                onSkip()
            }
            .keyboardShortcut(.cancelAction)
        }
    }
}
