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
                isRecording: $viewModel.isRecording,
                currentLanguage: $viewModel.currentLanguage,
                translationEnabled: $viewModel.translationEnabled,
                modelState: viewModel.modelState,
                onToggleRecording: { viewModel.toggleRecording() },
                onSwitchLanguage: { viewModel.switchLanguage($0) },
                onCopyAll: { viewModel.copyAllText() },
                onExport: { viewModel.exportText() },
                onClear: { viewModel.clearText() }
            )
        }
        .navigationTitle("Quick Transcriber")
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
        .translationTask(translationConfig) { session in
            await translationService.translateNewSegments(
                viewModel.confirmedSegments, using: session
            )
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
        .onReceive(NotificationCenter.default.publisher(for: .init("QuickTranscriber.menuIsRecordingQuery"))) { notification in
            if let callback = notification.userInfo?["callback"] as? (Bool) -> Void {
                callback(viewModel.isRecording)
            }
        }
        .sheet(isPresented: $viewModel.showPostMeetingTagging) {
            PostMeetingTagSheet(
                activeSpeakers: viewModel.activeSpeakers,
                allTags: viewModel.allTags,
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
            Spacer()
            fontSizeControls
            if viewModel.isRecording {
                Label("Recording", systemImage: "waveform")
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .font(.caption)
    }

    private var fontSizeControls: some View {
        HStack(spacing: 4) {
            Button(action: { viewModel.decreaseFontSize() }) {
                Text("A-")
                    .font(.caption2)
                    .frame(width: 24, height: 18)
            }
            .buttonStyle(.borderless)

            Text("\(Int(viewModel.fontSize))pt")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 30)

            Button(action: { viewModel.increaseFontSize() }) {
                Text("A+")
                    .font(.caption2)
                    .frame(width: 24, height: 18)
            }
            .buttonStyle(.borderless)
        }
        .padding(.trailing, 8)
    }

    private var transcriptionArea: some View {
        TranscriptionTextView(
            confirmedText: viewModel.confirmedText,
            unconfirmedText: viewModel.unconfirmedText,
            fontSize: viewModel.fontSize,
            confirmedSegments: viewModel.confirmedSegments,
            language: viewModel.currentLanguage.rawValue,
            silenceThreshold: viewModel.silenceLineBreakThreshold,
            labelDisplayNames: viewModel.speakerDisplayNames,
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
            confirmedSegments: translationService.translatedSegments,
            fontSize: viewModel.fontSize,
            language: viewModel.translationTargetLanguage.rawValue,
            silenceThreshold: viewModel.silenceLineBreakThreshold,
            labelDisplayNames: viewModel.speakerDisplayNames
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
