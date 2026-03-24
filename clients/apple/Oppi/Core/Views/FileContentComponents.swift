import SwiftUI

// MARK: - Source Context Helper

/// Creates a ``SelectedTextSourceContext`` for file content views.
///
/// Centralises the boilerplate shared by every file-type view so the
/// surface and language hint are the only things that vary per call site.
func fileContentSourceContext(
    filePath: String?,
    language: String? = nil,
    surface: SelectedTextSurfaceKind = .fullScreenCode
) -> SelectedTextSourceContext {
    SelectedTextSourceContext(
        sessionId: "",
        surface: surface,
        filePath: filePath,
        languageHint: language
    )
}

// MARK: - FileHeader

/// Header bar with language label, line count, and copy button.
struct FileHeader: View {
    let label: String
    let lineCount: Int
    let copyContent: String
    var showCopy = true
    var onExpand: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text")
                .font(.caption)
                .foregroundStyle(.themeCyan)
            Text(label)
                .font(.caption2.bold())
                .foregroundStyle(.themeFgDim)
            Text("\(lineCount) lines")
                .font(.caption2)
                .foregroundStyle(.themeComment)

            Spacer()

            if let onExpand {
                Button { onExpand() } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.themeFgDim)
            }

            if showCopy {
                CopyButton(content: copyContent)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.themeBgHighlight)
    }
}

// MARK: - CopyButton

/// Small copy button with "Copied" feedback.
struct CopyButton: View {
    let content: String
    @State private var isCopied = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        Button {
            resetTask?.cancel()
            UIPasteboard.general.string = content
            isCopied = true
            resetTask = Task {
                try? await Task.sleep(for: .seconds(2))
                isCopied = false
            }
        } label: {
            Label(
                isCopied ? "Copied" : "Copy",
                systemImage: isCopied ? "checkmark" : "doc.on.doc"
            )
            .font(.caption2)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.themeFgDim)
    }
}

// MARK: - TruncationNotice

/// "Showing X of Y lines" indicator.
struct TruncationNotice: View {
    let showing: Int
    let total: Int

    var body: some View {
        Text("Showing \(showing) of \(total) lines")
            .font(.caption2)
            .foregroundStyle(.themeComment)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .background(Color.themeBgHighlight.opacity(0.5))
    }
}

// MARK: - Line Number Info

/// Generate line number string and compute gutter width.
func lineNumberInfo(lineCount: Int, startLine: Int) -> (numbers: String, width: CGFloat) {
    let endLine = startLine + lineCount - 1
    let numbers = (startLine...endLine).map(String.init).joined(separator: "\n")
    let digits = max(String(endLine).count, 2)
    let width = CGFloat(digits) * 7.5
    return (numbers, width)
}

// MARK: - View Modifiers

extension View {
    /// Standard chrome for code block containers (dark bg, rounded corners).
    /// Border is optional for cleaner reader-style presentation.
    func codeBlockChrome(showBorder: Bool = true) -> some View {
        self
            .background(Color.themeBgDark)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                if showBorder {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.themeComment.opacity(0.35), lineWidth: 1)
                }
            }
    }
}

// MARK: - Native Code Body (UIKit-backed)

/// UIKit-backed code renderer wrapping ``NativeFullScreenCodeBody``.
///
/// Used by all code/JSON/plain-text views for both inline and document
/// presentation. Provides gutter line numbers, syntax highlighting
/// (off main thread), and bidirectional scrolling via `UITextView`.
///
/// When `maxHeight` is set (inline mode), reports estimated content
/// height via `sizeThatFits` so the view shrinks for short snippets.
/// Vertical bounce is disabled in inline mode.
struct NativeCodeBodyView: UIViewRepresentable {
    let content: String
    let language: String?
    let startLine: Int
    var maxHeight: CGFloat? = nil
    var selectedTextSourceContext: SelectedTextSourceContext? = nil

    @Environment(\.selectedTextPiActionRouter) private var selectedTextPiRouter

    /// Approximate line height for FullScreenCodeTypography.codeFont (12pt mono).
    private static let estimatedLineHeight: CGFloat = 15.0
    /// textContainerInset top + bottom (8 + 8).
    private static let estimatedVerticalPadding: CGFloat = 16.0

    func makeUIView(context: Context) -> NativeFullScreenCodeBody {
        NativeFullScreenCodeBody(
            content: content,
            language: language,
            startLine: startLine,
            palette: ThemeRuntimeState.currentThemeID().palette,
            alwaysBounceVertical: maxHeight == nil,
            selectedTextPiRouter: selectedTextPiRouter,
            selectedTextSourceContext: selectedTextSourceContext
        )
    }

    func updateUIView(_ uiView: NativeFullScreenCodeBody, context: Context) {}

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: NativeFullScreenCodeBody,
        context: Context
    ) -> CGSize? {
        guard let maxHeight else { return nil }
        let lineCount = content.split(separator: "\n", omittingEmptySubsequences: false).count
        let naturalHeight = CGFloat(lineCount) * Self.estimatedLineHeight + Self.estimatedVerticalPadding
        let width = proposal.width ?? UIScreen.main.bounds.width
        return CGSize(width: width, height: min(naturalHeight, maxHeight))
    }
}
