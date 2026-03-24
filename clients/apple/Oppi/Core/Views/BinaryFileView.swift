import SwiftUI

/// Placeholder view for binary files that cannot be rendered as text.
///
/// Shows file type icon and size. Used for archives (.gz, .zip),
/// compiled artifacts (.car, .nib, .dylib), and other non-text formats.
struct BinaryFileView: View {
    let filePath: String?
    let contentLength: Int

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.zipper")
                .font(.title2)
                .foregroundStyle(.themeComment)
            Text("Binary file — cannot preview")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.themeComment)
            if let ext = fileExtension {
                Text(".\(ext) • \(formattedSize)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.themeComment.opacity(0.7))
            } else {
                Text(formattedSize)
                    .font(.caption.monospaced())
                    .foregroundStyle(.themeComment.opacity(0.7))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    private var fileExtension: String? {
        guard let filePath else { return nil }
        let ext = (filePath as NSString).pathExtension.lowercased()
        return ext.isEmpty ? nil : ext
    }

    private var formattedSize: String {
        if contentLength < 1024 { return "\(contentLength) B" }
        if contentLength < 1024 * 1024 { return "\(contentLength / 1024) KB" }
        return String(format: "%.1f MB", Double(contentLength) / (1024 * 1024))
    }
}
