import Foundation

@MainActor
public final class ParametersStore: ObservableObject {
    public static let shared = ParametersStore()

    private static let userDefaultsKey = "transcriptionParameters"

    @Published public var parameters: TranscriptionParameters {
        didSet {
            saveParameters()
        }
    }

    public init() {
        if let data = UserDefaults.standard.data(forKey: Self.userDefaultsKey),
           let decoded = try? JSONDecoder().decode(TranscriptionParameters.self, from: data) {
            self.parameters = decoded
        } else {
            self.parameters = .default
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
