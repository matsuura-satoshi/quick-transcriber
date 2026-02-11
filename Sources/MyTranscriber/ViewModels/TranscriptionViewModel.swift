import Foundation
import SwiftUI
import AppKit
import Combine

public enum ModelState: Equatable {
    case notLoaded
    case loading
    case ready
    case error(String)
}

@MainActor
public final class TranscriptionViewModel: ObservableObject {
    @Published public var confirmedText: String = ""
    @Published public var unconfirmedText: String = ""
    @Published public var isRecording: Bool = false
    @Published public var currentLanguage: Language = .english
    @Published public var modelState: ModelState = .notLoaded
    @Published public var fontSize: CGFloat = 15.0

    private let service: TranscriptionService
    private let modelName: String
    private let parametersStore: ParametersStore
    private var previousSessionText: String = ""
    private var parametersCancellable: AnyCancellable?

    public init(
        engine: TranscriptionEngine = WhisperKitEngine(),
        modelName: String = "large-v3-v20240930_turbo",
        parametersStore: ParametersStore? = nil
    ) {
        self.service = TranscriptionService(engine: engine)
        self.modelName = modelName
        let resolvedStore = parametersStore ?? ParametersStore.shared
        self.parametersStore = resolvedStore

        parametersCancellable = resolvedStore.$parameters
            .dropFirst()
            .removeDuplicates()
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.isRecording else { return }
                NSLog("[MyTranscriber] Parameters changed, restarting recording")
                self.restartRecording()
            }
    }

    public func loadModel() async {
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

    public func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    public func switchLanguage(_ language: Language) {
        let wasRecording = isRecording
        if wasRecording {
            saveUnconfirmedText()
            isRecording = false
        }

        if !previousSessionText.isEmpty {
            let previousLang = currentLanguage.displayName
            let newLang = language.displayName
            previousSessionText += "\n--- \(previousLang) → \(newLang) ---\n"
            confirmedText = previousSessionText
        }

        currentLanguage = language

        if wasRecording {
            Task {
                await service.stopTranscription()
                try? await Task.sleep(nanoseconds: 100_000_000)
                startRecording()
            }
        }
    }

    public func clearText() {
        let wasRecording = isRecording
        if wasRecording {
            isRecording = false
        }
        previousSessionText = ""
        confirmedText = ""
        unconfirmedText = ""
        if wasRecording {
            Task {
                await service.stopTranscription()
                try? await Task.sleep(nanoseconds: 100_000_000)
                startRecording()
            }
        }
    }

    public func increaseFontSize() {
        fontSize = min(fontSize + 1, 30)
    }

    public func decreaseFontSize() {
        fontSize = max(fontSize - 1, 10)
    }

    public func copyAllText() {
        let text = displayText
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    public func exportText() {
        let text = displayText
        guard !text.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "transcription.txt"
        panel.begin { response in
            if response == .OK, let url = panel.url {
                do {
                    try text.write(to: url, atomically: true, encoding: .utf8)
                    NSLog("[MyTranscriber] Exported to: \(url.path)")
                } catch {
                    NSLog("[MyTranscriber] Export error: \(error)")
                }
            }
        }
    }

    public var displayText: String {
        if unconfirmedText.isEmpty {
            return confirmedText
        }
        if confirmedText.isEmpty {
            return unconfirmedText
        }
        return confirmedText + "\n" + unconfirmedText
    }

    // MARK: - Private

    private func restartRecording() {
        saveUnconfirmedText()
        isRecording = false
        Task {
            await service.stopTranscription()
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms safety margin
            startRecording()
        }
    }

    private func startRecording() {
        guard modelState == .ready else {
            NSLog("[MyTranscriber] Cannot record: model state = \(modelState)")
            return
        }
        isRecording = true
        let params = parametersStore.parameters
        NSLog("[MyTranscriber] Starting recording, language: \(currentLanguage.rawValue), params: \(params)")

        let sessionPrefix = self.previousSessionText
        Task {
            do {
                try await service.startTranscription(
                    language: currentLanguage.rawValue,
                    parameters: params
                ) { [weak self] state in
                    NSLog("[MyTranscriber] State update - confirmed: \(state.confirmedText.count) chars, unconfirmed: \(state.unconfirmedText.count) chars")
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if sessionPrefix.isEmpty {
                            self.confirmedText = state.confirmedText
                        } else if state.confirmedText.isEmpty {
                            self.confirmedText = sessionPrefix
                        } else {
                            self.confirmedText = sessionPrefix + "\n" + state.confirmedText
                        }
                        self.unconfirmedText = state.unconfirmedText
                    }
                }
            } catch {
                NSLog("[MyTranscriber] Recording error: \(error)")
                isRecording = false
            }
        }
    }

    private func saveUnconfirmedText() {
        if !unconfirmedText.isEmpty {
            if !confirmedText.isEmpty {
                confirmedText += "\n"
            }
            confirmedText += unconfirmedText
            unconfirmedText = ""
        }
        previousSessionText = confirmedText
    }

    private func stopRecording() {
        isRecording = false
        saveUnconfirmedText()
        Task { await service.stopTranscription() }
    }
}
