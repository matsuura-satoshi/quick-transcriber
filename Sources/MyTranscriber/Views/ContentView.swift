import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = TranscriptionViewModel()

    var body: some View {
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
                onClear: { viewModel.clearText() }
            )
        }
        .frame(minWidth: 600, minHeight: 400)
        .task {
            await viewModel.loadModel()
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
            if viewModel.isRecording {
                Label("Recording", systemImage: "waveform")
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .font(.caption)
    }

    private var transcriptionArea: some View {
        TranscriptionView(
            confirmedText: viewModel.confirmedText,
            unconfirmedText: viewModel.unconfirmedText
        )
        .frame(maxHeight: .infinity)
    }
}
