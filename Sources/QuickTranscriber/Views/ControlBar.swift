import SwiftUI

struct ControlBar: View {
    @Binding var isRecording: Bool
    @Binding var currentLanguage: Language
    let modelState: ModelState
    let onToggleRecording: () -> Void
    let onSwitchLanguage: (Language) -> Void
    let onCopyAll: () -> Void
    let onExport: () -> Void
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            recordButton
            languagePicker
            Spacer()
            copyAllButton
            exportButton
            clearButton
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var recordButton: some View {
        Button(action: onToggleRecording) {
            HStack(spacing: 6) {
                Image(systemName: isRecording ? "stop.circle.fill" : "mic.circle.fill")
                    .font(.title2)
                Text(isRecording ? "Stop" : "Record")
            }
        }
        .disabled(modelState != .ready)
        .keyboardShortcut("r", modifiers: .command)
    }

    private var languagePicker: some View {
        Picker("Language", selection: Binding(
            get: { currentLanguage },
            set: { onSwitchLanguage($0) }
        )) {
            ForEach(Language.allCases) { lang in
                Text(lang.displayName).tag(lang)
            }
        }
        .pickerStyle(.segmented)
        .frame(width: 200)
    }

    private var copyAllButton: some View {
        Button(action: onCopyAll) {
            HStack(spacing: 6) {
                Image(systemName: "doc.on.doc")
                Text("Copy")
            }
        }
    }

    private var exportButton: some View {
        Button(action: onExport) {
            HStack(spacing: 6) {
                Image(systemName: "square.and.arrow.up")
                Text("Export")
            }
        }
    }

    private var clearButton: some View {
        Button(action: onClear) {
            HStack(spacing: 6) {
                Image(systemName: "trash")
                Text("Clear")
            }
        }
    }
}
