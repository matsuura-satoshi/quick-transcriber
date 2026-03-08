import Foundation

public struct SpeakerId: Hashable, Sendable, Codable {
    public let uuid: UUID

    public var uuidString: String { uuid.uuidString }

    public init(_ uuid: UUID) {
        self.uuid = uuid
    }

    public init?(uuidString: String) {
        guard let uuid = UUID(uuidString: uuidString) else { return nil }
        self.uuid = uuid
    }
}
