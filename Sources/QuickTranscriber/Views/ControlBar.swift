import SwiftUI

struct ControlBar: View {
    @Binding var currentLanguage: Language
    @Binding var translationEnabled: Bool
    let onSwitchLanguage: (Language) -> Void
    let onCopyAll: () -> Void
    let onExport: () -> Void
    let onClear: () -> Void

    private let buttonPadding = EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)

    var body: some View {
        HStack(spacing: 8) {
            languagePicker
            translateButton
            Spacer()
            copyAllButton
            exportButton
            clearButton
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var languagePicker: some View {
        HStack(spacing: 0) {
            Image(systemName: "globe")
                .padding(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 4))
                .foregroundStyle(.secondary)
            ForEach(Language.allCases) { lang in
                Button(lang.displayName) {
                    onSwitchLanguage(lang)
                }
                .buttonStyle(.plain)
                .padding(buttonPadding)
                .background(currentLanguage == lang ? Color.accentColor : Color.clear)
                .foregroundStyle(currentLanguage == lang ? .white : .primary)
            }
        }
        .background(Color.secondary.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private var translateButton: some View {
        Button { translationEnabled.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: "translate")
                Text(translationEnabled ? "Hide" : "Translate")
            }
            .padding(buttonPadding)
        }
        .buttonStyle(.plain)
        .background(Color.secondary.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .keyboardShortcut("t", modifiers: .command)
    }

    private var copyAllButton: some View {
        Button(action: onCopyAll) {
            HStack(spacing: 6) {
                Image(systemName: "doc.on.doc")
                Text("Copy")
            }
            .padding(buttonPadding)
        }
        .buttonStyle(.plain)
        .background(Color.secondary.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private var exportButton: some View {
        Button(action: onExport) {
            HStack(spacing: 6) {
                Image(systemName: "square.and.arrow.down")
                Text("Save")
            }
            .padding(buttonPadding)
        }
        .buttonStyle(.plain)
        .background(Color.secondary.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private var clearButton: some View {
        Button(action: onClear) {
            HStack(spacing: 6) {
                Image(systemName: "trash")
                Text("Clear")
            }
            .padding(buttonPadding)
        }
        .buttonStyle(.plain)
        .background(Color.secondary.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}
