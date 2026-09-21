import SwiftUI

struct ThinkingOrbAcknowledgmentsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(ThinkingOrbAttribution.summary)
                    .font(.body)
                Text("Jakub Antalik — original thinking-orbs designs and engine")
                Link(
                    ThinkingOrbAttribution.originalDesignURLString,
                    destination: ThinkingOrbAttribution.originalDesignURL
                )
                Text("Haplo LLC — Swift ThinkingOrbs port")
                Link(
                    ThinkingOrbAttribution.swiftPortURLString,
                    destination: ThinkingOrbAttribution.swiftPortURL
                )
                Text("ThinkingOrbs commit \(ThinkingOrbAttribution.sourceCommit)")
                    .font(.footnote)
                    .foregroundStyle(.themeComment)
                Text(ThinkingOrbAttribution.licenseText)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .navigationTitle("Acknowledgments")
        #if canImport(UIKit)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
