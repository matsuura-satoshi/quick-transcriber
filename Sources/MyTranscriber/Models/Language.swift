public enum Language: String, CaseIterable, Identifiable, Sendable {
    case english = "en"
    case japanese = "ja"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .english: return "English"
        case .japanese: return "Japanese"
        }
    }
}
