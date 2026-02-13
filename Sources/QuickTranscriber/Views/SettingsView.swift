import SwiftUI
import AppKit

public struct SettingsView: View {
    @ObservedObject private var store = ParametersStore.shared

    public init() {}

    public var body: some View {
        TabView {
            TranscriptionSettingsTab(store: store)
                .tabItem {
                    Label("Transcription", systemImage: "waveform")
                }
            OutputSettingsTab()
                .tabItem {
                    Label("Output", systemImage: "folder")
                }
        }
        .frame(width: 480, height: 400)
    }
}

private struct TranscriptionSettingsTab: View {
    @ObservedObject var store: ParametersStore

    var body: some View {
        Form {
            chunkSection
            speakerSection
            decodingSection
            resetSection
        }
        .formStyle(.grouped)
    }

    // MARK: - Reset

    private var resetSection: some View {
        Section {
            Button("Reset to Defaults") {
                store.resetToDefaults()
            }
        }
    }

    // MARK: - Chunk Settings

    private var chunkSection: some View {
        Section("Chunk Settings") {
            DoubleSliderRow(
                label: "Chunk Duration",
                value: $store.parameters.chunkDuration,
                range: 1.0...10.0,
                step: 0.5,
                format: "%.1f s"
            )

            DoubleSliderRow(
                label: "Silence Cutoff",
                value: $store.parameters.silenceCutoffDuration,
                range: 0.3...2.0,
                step: 0.1,
                format: "%.1f s"
            )

            SliderRow(
                label: "Silence Threshold",
                value: $store.parameters.silenceEnergyThreshold,
                range: 0.001...0.1,
                step: 0.001,
                format: "%.3f"
            )

            DoubleSliderRow(
                label: "Line Break Silence",
                value: $store.parameters.silenceLineBreakThreshold,
                range: 0.5...3.0,
                step: 0.1,
                format: "%.1f s"
            )
        }
    }

    // MARK: - Speaker Detection

    private var speakerSection: some View {
        Section("Speaker Detection") {
            Toggle("Enable Speaker Diarization", isOn: $store.parameters.enableSpeakerDiarization)
        }
    }

    // MARK: - Decoding

    private var decodingSection: some View {
        Section("Decoding") {
            SliderRow(
                label: "Temperature",
                value: $store.parameters.temperature,
                range: 0.0...1.0,
                step: 0.05,
                format: "%.2f"
            )

            StepperRow(
                label: "Temperature Fallback Count",
                value: $store.parameters.temperatureFallbackCount,
                range: 0...5
            )

            StepperRow(
                label: "Sample Length",
                value: $store.parameters.sampleLength,
                range: 1...224
            )

            StepperRow(
                label: "Concurrent Workers",
                value: $store.parameters.concurrentWorkerCount,
                range: 1...8
            )
        }
    }
}

// MARK: - Output Settings

private struct OutputSettingsTab: View {
    @AppStorage("transcriptsDirectory") private var transcriptsDirectory: String = ""
    @AppStorage("isRecording") private var isRecording: Bool = false

    private var displayPath: String {
        let path = transcriptsDirectory.isEmpty
            ? TranscriptFileWriter.defaultDirectory.path
            : transcriptsDirectory
        return path.replacingOccurrences(
            of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
    }

    var body: some View {
        Form {
            Section("Transcript Output") {
                HStack {
                    Text("Output Folder")
                    Spacer()
                    Text(displayPath)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                HStack {
                    Button("Choose Folder...") {
                        chooseFolder()
                    }
                    .disabled(isRecording)
                    if !transcriptsDirectory.isEmpty {
                        Button("Reset to Default") {
                            transcriptsDirectory = ""
                        }
                        .disabled(isRecording)
                    }
                }
                if isRecording {
                    Text("Stop recording to change the output folder.")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }
            Section {
                Text("Transcripts are saved as **YYYY-MM-DD_HHmm_qt_transcript.md** with a **qt_transcript.md** symlink pointing to the latest file.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"
        panel.message = "Choose a folder for transcript output"
        if panel.runModal() == .OK, let url = panel.url {
            transcriptsDirectory = url.path
        }
    }
}

// MARK: - Reusable Controls

private struct SliderRow: View {
    let label: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    let step: Float
    let format: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                Spacer()
                Text(String(format: format, value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(
                    get: { Double(value) },
                    set: { value = Float($0) }
                ),
                in: Double(range.lowerBound)...Double(range.upperBound),
                step: Double(step)
            )
        }
    }
}

private struct DoubleSliderRow: View {
    let label: String
    @Binding var value: TimeInterval
    let range: ClosedRange<Double>
    let step: Double
    let format: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                Spacer()
                Text(String(format: format, value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, step: step)
        }
    }
}

private struct StepperRow: View {
    let label: String
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        Stepper(value: $value, in: range) {
            HStack {
                Text(label)
                Spacer()
                Text("\(value)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }
}
