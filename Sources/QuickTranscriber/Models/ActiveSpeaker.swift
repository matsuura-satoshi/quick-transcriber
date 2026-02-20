import Foundation

public struct ActiveSpeaker: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let speakerProfileId: UUID?     // StoredSpeakerProfileへのリンク
    public let sessionLabel: String        // ランタイムラベル (A, B, C...)
    public var displayName: String?
    public let source: Source

    public enum Source: String, Equatable, Sendable {
        case manual        // ユーザーが明示的に追加
        case autoDetected  // ダイアライザーが検出
    }

    public init(
        id: UUID = UUID(),
        speakerProfileId: UUID? = nil,
        sessionLabel: String,
        displayName: String? = nil,
        source: Source
    ) {
        self.id = id
        self.speakerProfileId = speakerProfileId
        self.sessionLabel = sessionLabel
        self.displayName = displayName
        self.source = source
    }
}
