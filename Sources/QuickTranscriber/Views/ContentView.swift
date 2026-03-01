import SwiftUI
import Translation

public struct ContentView: View {
    @ObservedObject var viewModel: TranscriptionViewModel
    @ObservedObject var translationService: TranslationService
    @State private var translationConfig: TranslationSession.Configuration?
    @State private var translationReady: Bool = false

    public init(viewModel: TranscriptionViewModel) {
        self.viewModel = viewModel
        self.translationService = viewModel.translationService
    }

    public var body: some View {
        VStack(spacing: 0) {
            statusBar
            Divider()
            HSplitView {
                transcriptionArea
                    .frame(minWidth: 250)
                if viewModel.translationEnabled {
                    translationArea
                        .frame(minWidth: 250)
                }
            }
            Divider()
            ControlBar(
                currentLanguage: $viewModel.currentLanguage,
                translationEnabled: $viewModel.translationEnabled,
                onSwitchLanguage: { viewModel.switchLanguage($0) },
                onCopyAll: { viewModel.copyAllText() },
                onExport: { viewModel.exportText() },
                onClear: { viewModel.clearText() }
            )
        }
        .onKeyPress(.space) {
            guard viewModel.modelState == .ready else { return .ignored }
            viewModel.toggleRecording()
            return .handled
        }
        .navigationTitle("Quick Transcriber \(Constants.Version.versionString)")
        .frame(minWidth: viewModel.translationEnabled ? 900 : 600, minHeight: 400)
        .task {
            await viewModel.loadModel()
            if viewModel.translationEnabled {
                updateTranslationConfig()
            }
        }
        .onChange(of: viewModel.translationEnabled) { _, enabled in
            if enabled {
                translationReady = false
                updateTranslationConfig()
            } else {
                translationConfig = nil
                translationReady = false
                translationService.reset()
            }
        }
        .onChange(of: viewModel.currentLanguage) { _, _ in
            if viewModel.translationEnabled {
                translationReady = false
                updateTranslationConfig()
            }
        }
        .onChange(of: viewModel.confirmedSegments.count) { _, _ in
            if viewModel.translationEnabled && translationReady {
                translationConfig?.invalidate()
            }
        }
        .onChange(of: viewModel.isRecording) { _, isRecording in
            if !isRecording && viewModel.translationEnabled && translationReady {
                translationConfig?.invalidate()
            }
        }
        .translationTask(translationConfig) { session in
            let segments = viewModel.confirmedSegments
            await translationService.translateNewSegments(
                segments,
                using: session,
                sourceLanguage: viewModel.currentLanguage.rawValue
            )
            if !viewModel.isRecording {
                await translationService.finalizeLastGroup(
                    segments, using: session
                )
            }
            if !translationReady {
                translationReady = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("QuickTranscriber.menuCopyAll"))) { _ in
            viewModel.copyAllText()
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("QuickTranscriber.menuExport"))) { _ in
            viewModel.exportText()
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("QuickTranscriber.menuClear"))) { _ in
            viewModel.clearText()
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("QuickTranscriber.menuIncreaseFontSize"))) { _ in
            viewModel.increaseFontSize()
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("QuickTranscriber.menuDecreaseFontSize"))) { _ in
            viewModel.decreaseFontSize()
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("QuickTranscriber.menuResetFontSize"))) { _ in
            viewModel.resetFontSize()
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("QuickTranscriber.menuToggleRecording"))) { _ in
            viewModel.toggleRecording()
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("QuickTranscriber.menuIsRecordingQuery"))) { notification in
            if let callback = notification.userInfo?["callback"] as? (Bool) -> Void {
                callback(viewModel.isRecording)
            }
        }
        .sheet(isPresented: $viewModel.showPostMeetingTagging) {
            PostMeetingTagSheet(
                activeSpeakers: viewModel.activeSpeakers,
                allTags: viewModel.allTags,
                preExistingProfileIds: viewModel.preExistingProfileIds,
                onApply: { tag, profileIds in
                    viewModel.bulkAddTag(tag, to: profileIds)
                    viewModel.showPostMeetingTagging = false
                },
                onSkip: {
                    viewModel.showPostMeetingTagging = false
                }
            )
        }
    }

    @ViewBuilder
    private var statusBar: some View {
        HStack {
            Button(action: { viewModel.toggleRecording() }) {
                Image(systemName: viewModel.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                    .font(.title2)
                    .foregroundStyle(viewModel.isRecording ? .red : .primary)
            }
            .buttonStyle(.borderless)
            .disabled(viewModel.modelState != .ready)
            if viewModel.isRecording {
                Label("Recording", systemImage: "waveform")
                    .foregroundStyle(.red)
            } else {
                Text("Waiting")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            switch viewModel.modelState {
            case .notLoaded:
                Label("Not loaded", systemImage: "circle")
                    .foregroundStyle(.secondary)
            case .loading:
                ProgressView()
                    .controlSize(.small)
                Text("Loading model...")
                    .foregroundStyle(.secondary)
            case .ready:
                Label("Ready", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .error(let message):
                Label(message, systemImage: "exclamation.triangle.fill")
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var transcriptionArea: some View {
        TranscriptionTextView(
            confirmedText: viewModel.confirmedText,
            unconfirmedText: viewModel.unconfirmedText,
            fontSize: viewModel.fontSize,
            confirmedSegments: viewModel.confirmedSegments,
            language: viewModel.currentLanguage.rawValue,
            silenceThreshold: viewModel.silenceLineBreakThreshold,
            speakerDisplayNames: viewModel.speakerDisplayNames,
            availableSpeakers: viewModel.availableSpeakers,
            onReassignBlock: { segmentIndex, newSpeaker in
                viewModel.reassignSpeakerForBlock(segmentIndex: segmentIndex, newSpeaker: newSpeaker)
            },
            onReassignSelection: { range, newSpeaker, map in
                viewModel.reassignSpeakerForSelection(selectionRange: range, newSpeaker: newSpeaker, segmentMap: map)
            }
        )
        .frame(maxHeight: .infinity)
    }

    private var translationArea: some View {
        TranslationTextView(
            confirmedSegments: translationService.displaySegments,
            fontSize: viewModel.fontSize,
            language: viewModel.translationTargetLanguage.rawValue,
            silenceThreshold: viewModel.silenceLineBreakThreshold,
            speakerDisplayNames: viewModel.speakerDisplayNames
        )
        .frame(maxHeight: .infinity)
    }

    private func updateTranslationConfig() {
        let source: Locale.Language
        let target: Locale.Language
        if viewModel.currentLanguage == .english {
            source = Locale.Language(identifier: "en")
            target = Locale.Language(identifier: "ja")
        } else {
            source = Locale.Language(identifier: "ja")
            target = Locale.Language(identifier: "en")
        }
        translationConfig = TranslationSession.Configuration(
            source: source,
            target: target
        )
    }
}
