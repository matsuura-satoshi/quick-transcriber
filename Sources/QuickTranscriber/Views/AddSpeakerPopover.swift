import SwiftUI

struct AddSpeakerPopover: View {
    let speakers: [RegisteredSpeakerInfo]
    let allTags: [String]
    let onSelect: (UUID) -> Void
    let onDismiss: () -> Void

    @State private var searchText: String = ""
    @State private var selectedTags: Set<String> = []

    var filteredSpeakers: [RegisteredSpeakerInfo] {
        speakers.filter { speaker in
            if speaker.isAlreadyActive { return false }
            let matchesSearch = searchText.isEmpty
                || (speaker.displayName?.localizedCaseInsensitiveContains(searchText) ?? false)
                || speaker.label.localizedCaseInsensitiveContains(searchText)
            let matchesTags = selectedTags.isEmpty
                || !selectedTags.isDisjoint(with: speaker.tags)
            return matchesSearch && matchesTags
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            TextField("Search speakers...", text: $searchText)
                .textFieldStyle(.roundedBorder)

            if !allTags.isEmpty {
                tagFilter
            }

            Divider()

            if filteredSpeakers.isEmpty {
                Text("No matching speakers")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(filteredSpeakers) { speaker in
                            speakerRow(speaker)
                        }
                    }
                }
                .frame(maxHeight: 200)
            }
        }
        .padding(12)
        .frame(width: 260)
    }

    private var tagFilter: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(allTags, id: \.self) { tag in
                    Button {
                        if selectedTags.contains(tag) {
                            selectedTags.remove(tag)
                        } else {
                            selectedTags.insert(tag)
                        }
                    } label: {
                        Text(tag)
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(selectedTags.contains(tag) ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.1))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func speakerRow(_ speaker: RegisteredSpeakerInfo) -> some View {
        Button {
            onSelect(speaker.profileId)
            onDismiss()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(speaker.displayName ?? speaker.label)
                        .font(.body)
                    if let displayName = speaker.displayName, displayName != speaker.label {
                        Text(speaker.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if !speaker.tags.isEmpty {
                    Text(speaker.tags.joined(separator: ", "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }
}
