import Foundation
import SwiftUI

enum ModelState: Equatable {
    case notLoaded
    case loading
    case ready
    case error(String)
}

@MainActor
final class TranscriptionViewModel: ObservableObject {
    @Published var confirmedText: String = ""
    @Published var unconfirmedText: String = ""
    @Published var isRecording: Bool = false
    @Published var currentLanguage: Language = .english
    @Published var modelState: ModelState = .notLoaded

    private let service: TranscriptionService
    private let modelName: String

    init(
        engine: TranscriptionEngine = WhisperKitEngine(),
        modelName: String = "large-v3-v20240930_turbo"
    ) {
        self.service = TranscriptionService(engine: engine)
        self.modelName = modelName
    }

    func loadModel() async {
        modelState = .loading
        NSLog("[MyTranscriber] Loading model: \(modelName)")
        do {
            try await service.prepare(model: modelName)
            modelState = .ready
            NSLog("[MyTranscriber] Model ready")
        } catch {
            modelState = .error(error.localizedDescription)
            NSLog("[MyTranscriber] Model load error: \(error)")
        }
    }

    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    func switchLanguage(_ language: Language) {
        let wasRecording = isRecording
        if wasRecording {
            stopRecording()
        }

        if !confirmedText.isEmpty || !unconfirmedText.isEmpty {
            let previousLang = currentLanguage.displayName
            let newLang = language.displayName
            confirmedText += unconfirmedText
            confirmedText += "\n--- \(previousLang) → \(newLang) ---\n"
            unconfirmedText = ""
        }

        currentLanguage = language

        if wasRecording {
            startRecording()
        }
    }

    func clearText() {
        confirmedText = ""
        unconfirmedText = ""
    }

    var displayText: String {
        if unconfirmedText.isEmpty {
            return confirmedText
        }
        if confirmedText.isEmpty {
            return unconfirmedText
        }
        return confirmedText + "\n" + unconfirmedText
    }

    // MARK: - Private

    private func startRecording() {
        guard modelState == .ready else {
            NSLog("[MyTranscriber] Cannot record: model state = \(modelState)")
            return
        }
        isRecording = true
        NSLog("[MyTranscriber] Starting recording, language: \(currentLanguage.rawValue)")

        Task {
            do {
                try await service.startTranscription(
                    language: currentLanguage.rawValue
                ) { [weak self] state in
                    NSLog("[MyTranscriber] State update - confirmed: \(state.confirmedText.count) chars, unconfirmed: \(state.unconfirmedText.count) chars")
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.confirmedText = state.confirmedText
                        self.unconfirmedText = state.unconfirmedText
                    }
                }
            } catch {
                NSLog("[MyTranscriber] Recording error: \(error)")
                isRecording = false
            }
        }
    }

    private func stopRecording() {
        isRecording = false
        confirmedText += unconfirmedText
        unconfirmedText = ""
        Task {
            await service.stopTranscription()
        }
    }
}
