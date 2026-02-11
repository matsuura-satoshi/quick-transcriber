import Foundation

public enum EngineType: String, Codable, CaseIterable, Identifiable {
    case streaming = "streaming"
    case chunked = "chunked"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .streaming: return "Streaming"
        case .chunked: return "Chunked"
        }
    }
}

@MainActor
public final class ParametersStore: ObservableObject {
    public static let shared = ParametersStore()

    private static let userDefaultsKey = "transcriptionParameters"
    private static let engineTypeKey = "engineType"

    @Published public var parameters: TranscriptionParameters {
        didSet {
            saveParameters()
        }
    }

    @Published public var engineType: EngineType {
        didSet {
            UserDefaults.standard.set(engineType.rawValue, forKey: Self.engineTypeKey)
        }
    }

    public init() {
        if let data = UserDefaults.standard.data(forKey: Self.userDefaultsKey),
           let decoded = try? JSONDecoder().decode(TranscriptionParameters.self, from: data) {
            self.parameters = decoded
        } else {
            self.parameters = .default
        }

        if let raw = UserDefaults.standard.string(forKey: Self.engineTypeKey),
           let type = EngineType(rawValue: raw) {
            self.engineType = type
        } else {
            self.engineType = .streaming
        }
    }

    public func resetToDefaults() {
        parameters = .default
    }

    private func saveParameters() {
        if let data = try? JSONEncoder().encode(parameters) {
            UserDefaults.standard.set(data, forKey: Self.userDefaultsKey)
        }
    }
}
