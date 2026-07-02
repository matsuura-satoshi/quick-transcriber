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
        ControlBarButton(systemImage: "translate", title: translationEnabled ? "Hide" : "Translate") {
            translationEnabled.toggle()
        }
        .keyboardShortcut("t", modifiers: .command)
    }

    private var copyAllButton: some View {
        ControlBarButton(systemImage: "doc.on.doc", title: "Copy", action: onCopyAll)
    }

    private var exportButton: some View {
        ControlBarButton(systemImage: "square.and.arrow.down", title: "Save", action: onExport)
    }

    private var clearButton: some View {
        ControlBarButton(systemImage: "trash", title: "Clear", action: onClear)
    }
}

private struct ControlBarButton: View {
    let systemImage: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                Text(title)
            }
            .padding(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
        }
        .buttonStyle(.plain)
        .background(Color.secondary.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}
