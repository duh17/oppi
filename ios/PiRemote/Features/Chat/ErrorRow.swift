import SwiftUI
import UIKit

struct ErrorRow: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.tokyoRed)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.tokyoFg)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.tokyoRed.opacity(0.18))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .contextMenu {
            Button("Copy Error", systemImage: "doc.on.doc") {
                UIPasteboard.general.string = message
            }
        }
    }
}
