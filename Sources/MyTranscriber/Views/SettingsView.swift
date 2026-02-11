import SwiftUI

public struct SettingsView: View {
    @ObservedObject private var store = ParametersStore.shared

    public init() {}

    public var body: some View {
        TabView {
            TranscriptionSettingsTab(store: store)
                .tabItem {
                    Label("Transcription", systemImage: "waveform")
                }
        }
        .frame(width: 480, height: 520)
    }
}

private struct TranscriptionSettingsTab: View {
    @ObservedObject var store: ParametersStore

    var body: some View {
        Form {
            vadSection
            segmentSection
            decodingSection
            thresholdsSection

            Section("Presets") {
                HStack {
                    Spacer()
                    Button("Aggressive (confirm fast)") {
                        store.parameters = .aggressive
                    }
                    Button("Default") {
                        store.resetToDefaults()
                    }
                    Spacer()
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - VAD

    private var vadSection: some View {
        Section("Voice Activity Detection") {
            Toggle("Use VAD", isOn: $store.parameters.useVAD)

            SliderRow(
                label: "Silence Threshold",
                value: $store.parameters.silenceThreshold,
                range: 0.0...1.0,
                step: 0.05,
                format: "%.2f"
            )

            SliderRow(
                label: "No Speech Threshold",
                value: $store.parameters.noSpeechThreshold,
                range: 0.0...1.0,
                step: 0.05,
                format: "%.2f"
            )
        }
    }

    // MARK: - Segment Confirmation

    private var segmentSection: some View {
        Section("Segment Confirmation") {
            StepperRow(
                label: "Required Segments",
                value: $store.parameters.requiredSegmentsForConfirmation,
                range: 1...10
            )

            StepperRow(
                label: "Compression Check Window",
                value: $store.parameters.compressionCheckWindow,
                range: 1...100
            )

            SliderRow(
                label: "Window Clip Time",
                value: $store.parameters.windowClipTime,
                range: 0.0...5.0,
                step: 0.1,
                format: "%.1f s"
            )
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

    // MARK: - Thresholds

    private var thresholdsSection: some View {
        Section("Quality Thresholds") {
            SliderRow(
                label: "Compression Ratio",
                value: $store.parameters.compressionRatioThreshold,
                range: 0.0...5.0,
                step: 0.1,
                format: "%.1f"
            )

            SliderRow(
                label: "Log Prob Threshold",
                value: $store.parameters.logProbThreshold,
                range: -5.0...0.0,
                step: 0.1,
                format: "%.1f"
            )

            SliderRow(
                label: "First Token Log Prob",
                value: $store.parameters.firstTokenLogProbThreshold,
                range: -5.0...0.0,
                step: 0.1,
                format: "%.1f"
            )
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
