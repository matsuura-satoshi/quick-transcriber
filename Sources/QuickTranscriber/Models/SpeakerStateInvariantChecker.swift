import Foundation

struct SpeakerStateInvariantChecker {
    static func verify(
        segments: [ConfirmedSegment],
        activeSpeakers: [ActiveSpeaker],
        historicalNames: [String: String],
        speakerDisplayNames: [String: String],
        profileStore: SpeakerProfileStore
    ) {
        #if DEBUG
        // 1. Every speaker UUID in segments exists in activeSpeakers or historicalNames
        for seg in segments {
            guard let speaker = seg.speaker else { continue }
            assert(
                activeSpeakers.contains(where: { $0.id.uuidString == speaker })
                    || historicalNames[speaker] != nil,
                "Orphaned speaker UUID in segment: \(speaker)"
            )
        }
        // 2. Every activeSpeaker.speakerProfileId exists in profileStore
        for speaker in activeSpeakers {
            if let pid = speaker.speakerProfileId {
                assert(
                    profileStore.profiles.contains(where: { $0.id == pid }),
                    "Active speaker \(speaker.id) linked to non-existent profile \(pid)"
                )
            }
        }
        // 3. speakerDisplayNames covers all speaker UUIDs in segments
        for seg in segments {
            guard let speaker = seg.speaker else { continue }
            assert(
                speakerDisplayNames[speaker] != nil || historicalNames[speaker] != nil,
                "No display name for speaker UUID: \(speaker)"
            )
        }
        #endif
    }
}
