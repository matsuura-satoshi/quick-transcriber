import SwiftUI

struct TranscriptionView: View {
    let confirmedText: String
    let unconfirmedText: String

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if !confirmedText.isEmpty {
                        Text(confirmedText)
                            .textSelection(.enabled)
                            .foregroundStyle(.primary)
                    }

                    if !unconfirmedText.isEmpty {
                        Text(unconfirmedText)
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
                    }

                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .onChange(of: confirmedText) {
                withAnimation {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .onChange(of: unconfirmedText) {
                withAnimation {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }
}
