import SwiftUI

enum TagMatchMode: String, CaseIterable {
    case any = "Any selected"
    case all = "All selected"
}

struct TagFilterSheet: View {
    let allTags: [String]
    let profiles: [RegisteredSpeakerInfo]
    let onAdd: (UUID) -> Void
    let onBulkAdd: ([UUID]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedTags: Set<String> = []
    @State private var matchMode: TagMatchMode = .any

    static func filterProfiles(
        _ profiles: [RegisteredSpeakerInfo],
        selectedTags: Set<String>,
        matchMode: TagMatchMode
    ) -> [RegisteredSpeakerInfo] {
        guard !selectedTags.isEmpty else { return profiles }
        return profiles.filter { profile in
            switch matchMode {
            case .any:
                return !selectedTags.isDisjoint(with: profile.tags)
            case .all:
                return selectedTags.isSubset(of: Set(profile.tags))
            }
        }
    }

    private var matchingProfiles: [RegisteredSpeakerInfo] {
        Self.filterProfiles(profiles, selectedTags: selectedTags, matchMode: matchMode)
    }

    private var addableProfiles: [RegisteredSpeakerInfo] {
        matchingProfiles.filter { !$0.isAlreadyActive }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Speakers by Tag")
                .font(.headline)

            FlowLayout(spacing: 6) {
                ForEach(allTags, id: \.self) { tag in
                    TagFilterPill(label: tag, isSelected: selectedTags.contains(tag)) {
                        if selectedTags.contains(tag) {
                            selectedTags.remove(tag)
                        } else {
                            selectedTags.insert(tag)
                        }
                    }
                }
            }

            if !selectedTags.isEmpty {
                Picker("Match", selection: $matchMode) {
                    ForEach(TagMatchMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 250)
            }

            Divider()

            if matchingProfiles.isEmpty {
                Text("No matching speakers")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                Text("Matching (\(matchingProfiles.count)):")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                List {
                    ForEach(matchingProfiles) { profile in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(profile.displayName ?? profile.label)
                                if !profile.tags.isEmpty {
                                    Text(profile.tags.joined(separator: ", "))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if profile.isAlreadyActive {
                                Text("Added")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Button("+ Add") {
                                    onAdd(profile.profileId)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    }
                }
                .frame(minHeight: 100, maxHeight: 250)
            }

            HStack {
                Button("Add All Matching") {
                    onBulkAdd(addableProfiles.map { $0.profileId })
                }
                .disabled(addableProfiles.isEmpty)

                Spacer()

                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding()
        .frame(minWidth: 380, maxWidth: 380, minHeight: 200)
    }
}
