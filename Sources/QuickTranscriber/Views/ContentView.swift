import SwiftUI

public struct ContentView: View {
    @ObservedObject var viewModel: TranscriptionViewModel

    public init(viewModel: TranscriptionViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 0) {
            statusBar
            Divider()
            transcriptionArea
            Divider()
            ControlBar(
                isRecording: $viewModel.isRecording,
                currentLanguage: $viewModel.currentLanguage,
                modelState: viewModel.modelState,
                onToggleRecording: { viewModel.toggleRecording() },
                onSwitchLanguage: { viewModel.switchLanguage($0) },
                onCopyAll: { viewModel.copyAllText() },
                onExport: { viewModel.exportText() },
                onClear: { viewModel.clearText() }
            )
        }
        .navigationTitle("Quick Transcriber")
        .frame(minWidth: 600, minHeight: 400)
        .task {
            await viewModel.loadModel()
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
            labelDisplayNames: viewModel.labelDisplayNames,
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
}
