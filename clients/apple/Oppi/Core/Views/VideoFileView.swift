import SwiftUI

/// Placeholder view for video file content.
///
/// Video files cannot be meaningfully previewed from string content
/// in the file browser. Shows file type info instead.
struct VideoFileView: View {
    let content: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "film")
                .font(.title2)
                .foregroundStyle(.themeComment)
            Text("Video file")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.themeComment)
            Text(formattedSize)
                .font(.caption.monospaced())
                .foregroundStyle(.themeComment.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    private var formattedSize: String {
        SessionFormatting.byteCount(content.utf8.count)
    }
}
