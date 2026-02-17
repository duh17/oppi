import SwiftUI
import UIKit

/// Full-screen content viewer for tool output.
///
/// Removes inline height caps so users can read long files comfortably.
/// Supports three modes:
/// - `.code`: syntax-highlighted source with line numbers
/// - `.diff`: unified diff with add/remove coloring
/// - `.markdown`: full markdown note/reader rendering

enum FullScreenCodeContent {
    case code(content: String, language: String?, filePath: String?, startLine: Int)
    case diff(oldText: String, newText: String, filePath: String?, precomputedLines: [DiffLine]?)
    case markdown(content: String, filePath: String?)
}

struct FullScreenCodeView: View {
    let content: FullScreenCodeContent
    @State private var showSource = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack(alignment: .topLeading) {
                Color.tokyoBgDark.ignoresSafeArea()
                codeBody
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(.tokyoCyan)
                }
                ToolbarItem(placement: .principal) {
                    titleView
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    if case .markdown = content {
                        Button(showSource ? "Reader" : "Source") {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                showSource.toggle()
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.tokyoBlue)
                    }
                    copyButton
                }
            }
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(Color.tokyoBgHighlight, for: .navigationBar)
        }
    }

    // MARK: - Title

    @ViewBuilder
    private var titleView: some View {
        switch content {
        case .code(_, let language, let filePath, _):
            VStack(spacing: 1) {
                if let path = filePath {
                    Text(path.shortenedPath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tokyoFg)
                        .lineLimit(1)
                }
                Text(language ?? "code")
                    .font(.caption2)
                    .foregroundStyle(.tokyoComment)
            }
        case .diff(_, _, let filePath, _):
            VStack(spacing: 1) {
                if let path = filePath {
                    Text(path.shortenedPath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tokyoFg)
                        .lineLimit(1)
                }
                Text("Diff")
                    .font(.caption2)
                    .foregroundStyle(.tokyoComment)
            }
        case .markdown(_, let filePath):
            VStack(spacing: 1) {
                if let path = filePath {
                    Text(path.shortenedPath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tokyoFg)
                        .lineLimit(1)
                }
                Text("Markdown")
                    .font(.caption2)
                    .foregroundStyle(.tokyoComment)
            }
        }
    }

    // MARK: - Copy

    @ViewBuilder
    private var copyButton: some View {
        switch content {
        case .code(let text, _, _, _):
            CopyIconButton(text: text)
        case .diff(_, let newText, _, _):
            CopyIconButton(text: newText)
        case .markdown(let text, _):
            CopyIconButton(text: text)
        }
    }

    // MARK: - Body

    @ViewBuilder
    private var codeBody: some View {
        switch content {
        case .code(let text, let language, _, let startLine):
            FullScreenCodeBody(content: text, language: language, startLine: startLine)
        case .diff(let oldText, let newText, let filePath, let precomputedLines):
            FullScreenDiffBody(
                oldText: oldText,
                newText: newText,
                filePath: filePath,
                precomputedLines: precomputedLines
            )
        case .markdown(let text, _):
            if showSource {
                FullScreenSourceBody(content: text)
            } else {
                FullScreenMarkdownBody(content: text)
            }
        }
    }
}

// MARK: - Full Screen Source Body

private struct FullScreenSourceBody: View {
    let content: String

    var body: some View {
        ScrollView(.vertical) {
            Text(content)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.tokyoFg)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.tokyoBgDark)
    }
}

// MARK: - Full Screen Markdown Body

private struct FullScreenMarkdownBody: View {
    let content: String

    var body: some View {
        NativeMarkdownReaderView(content: content)
            .background(Color.tokyoBgDark)
    }
}

private struct NativeMarkdownReaderView: UIViewRepresentable {
    let content: String

    func makeUIView(context: Context) -> NativeMarkdownReaderContainerView {
        let view = NativeMarkdownReaderContainerView()
        view.apply(content: content)
        return view
    }

    func updateUIView(_ uiView: NativeMarkdownReaderContainerView, context: Context) {
        uiView.apply(content: content)
    }
}

private final class NativeMarkdownReaderContainerView: UIView {
    private let scrollView = UIScrollView()
    private let markdownView = AssistantMarkdownContentView()
    private let markdownWidthConstraint: NSLayoutConstraint
    private var lastContent: String?
    private var lastThemeID: ThemeID?

    override init(frame: CGRect) {
        markdownWidthConstraint = markdownView.widthAnchor.constraint(
            equalTo: scrollView.frameLayoutGuide.widthAnchor,
            constant: -24
        )

        super.init(frame: frame)

        backgroundColor = UIColor(Color.tokyoBgDark)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.backgroundColor = UIColor(Color.tokyoBgDark)
        scrollView.alwaysBounceVertical = true
        scrollView.alwaysBounceHorizontal = false
        scrollView.showsVerticalScrollIndicator = true

        markdownView.translatesAutoresizingMaskIntoConstraints = false
        markdownView.backgroundColor = .clear

        addSubview(scrollView)
        scrollView.addSubview(markdownView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            markdownView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 12),
            markdownView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -12),
            markdownView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 10),
            markdownView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -10),
            markdownWidthConstraint,
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func apply(content: String) {
        let themeID = ThemeRuntimeState.currentThemeID()
        guard content != lastContent || themeID != lastThemeID else { return }

        lastContent = content
        lastThemeID = themeID
        backgroundColor = UIColor(themeID.palette.bgDark)
        scrollView.backgroundColor = UIColor(themeID.palette.bgDark)

        markdownView.apply(configuration: .init(
            content: content,
            isStreaming: false,
            themeID: themeID
        ))
    }
}

// MARK: - Full Screen Code Body

/// Full code view without height cap — scrolls vertically and horizontally.
private struct FullScreenCodeBody: View {
    let content: String
    let language: String?
    let startLine: Int

    @State private var highlighted: AttributedString?

    private static let highlightCache = NSCache<NSString, FullScreenHighlightCacheEntry>()

    private var syntaxLanguage: SyntaxLanguage {
        guard let lang = language else { return .unknown }
        return SyntaxLanguage.detect(lang)
    }

    private var highlightCacheKey: NSString {
        var hasher = Hasher()
        hasher.combine(language ?? "")
        hasher.combine(content)
        return NSString(string: String(hasher.finalize()))
    }

    private var highlightTaskID: Int {
        var hasher = Hasher()
        hasher.combine(language ?? "")
        hasher.combine(content)
        return hasher.finalize()
    }

    var body: some View {
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        let lineCount = lines.count
        let (numbers, gutterWidth) = lineNumberInfo(lineCount: lineCount, startLine: startLine)

        ScrollView([.vertical, .horizontal]) {
            HStack(alignment: .top, spacing: 0) {
                // Gutter
                Text(numbers)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.tokyoComment)
                    .multilineTextAlignment(.trailing)
                    .frame(width: gutterWidth, alignment: .trailing)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 8)

                // Separator
                Rectangle()
                    .fill(Color.tokyoComment.opacity(0.2))
                    .frame(width: 1)

                // Code
                Group {
                    if let highlighted {
                        Text(highlighted)
                            .font(.system(size: 12, design: .monospaced))
                    } else {
                        Text(content)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.tokyoFg)
                    }
                }
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.tokyoBgDark)
        .transaction { transaction in
            transaction.animation = nil
        }
        .task(id: highlightTaskID) {
            let lang = syntaxLanguage
            guard lang != .unknown else {
                highlighted = nil
                return
            }

            let cacheKey = highlightCacheKey
            if let cached = Self.highlightCache.object(forKey: cacheKey)?.value {
                highlighted = cached
                return
            }

            let text = content
            let highlightedText = await Task.detached(priority: .userInitiated) {
                SyntaxHighlighter.highlight(text, language: lang)
            }.value
            guard !Task.isCancelled else { return }

            Self.highlightCache.setObject(
                FullScreenHighlightCacheEntry(value: highlightedText),
                forKey: cacheKey
            )

            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                highlighted = highlightedText
            }
        }
    }
}

private final class FullScreenHighlightCacheEntry: NSObject {
    let value: AttributedString

    init(value: AttributedString) {
        self.value = value
    }
}

// MARK: - Full Screen Diff Body

/// Full diff view without height cap.
private struct FullScreenDiffBody: View {
    let oldText: String
    let newText: String
    let filePath: String?
    let precomputedLines: [DiffLine]?

    private var diffLines: [DiffLine] {
        precomputedLines ?? DiffEngine.compute(old: oldText, new: newText)
    }

    private var language: SyntaxLanguage {
        guard let path = filePath else { return .unknown }
        let ext = (path as NSString).pathExtension
        return ext.isEmpty ? .unknown : SyntaxLanguage.detect(ext)
    }

    @Environment(\.theme) private var theme

    var body: some View {
        let lines = diffLines
        let numberedLines = makeNumberedLines(lines)
        let stats = DiffEngine.stats(lines)
        let lang = language

        VStack(alignment: .leading, spacing: 0) {
            // Stats bar
            HStack(spacing: 12) {
                if stats.added > 0 {
                    Text("+\(stats.added)")
                        .font(.caption.monospaced().bold())
                        .foregroundStyle(theme.diff.addedAccent)
                }
                if stats.removed > 0 {
                    Text("-\(stats.removed)")
                        .font(.caption.monospaced().bold())
                        .foregroundStyle(theme.diff.removedAccent)
                }
                Text("\(lines.count) lines")
                    .font(.caption2)
                    .foregroundStyle(theme.text.tertiary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(theme.bg.highlight)

            // Diff rows — no height cap
            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(numberedLines.enumerated()), id: \.offset) { _, numbered in
                        diffRow(numbered, lang: lang)
                    }
                }
            }
            .background(Color.tokyoBgDark)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.tokyoBgDark)
    }

    @ViewBuilder
    private func diffRow(_ numbered: NumberedDiffLine, lang: SyntaxLanguage) -> some View {
        let line = numbered.line

        HStack(alignment: .top, spacing: 0) {
            // Left accent bar
            Rectangle()
                .fill(accentColor(for: line.kind))
                .frame(width: 3)

            // Gutter prefix
            Text(line.kind.prefix)
                .font(.system(size: 12, design: .monospaced).bold())
                .foregroundStyle(prefixColor(for: line.kind))
                .frame(width: 18, alignment: .center)

            // Old/New line numbers
            Text(numbered.oldLine.map(String.init) ?? "")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(theme.text.tertiary)
                .frame(width: 44, alignment: .trailing)
            Text(numbered.newLine.map(String.init) ?? "")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(theme.text.tertiary)
                .frame(width: 44, alignment: .trailing)
                .padding(.trailing, 8)

            // Code text
            if lang != .unknown, line.kind == .context {
                Text(SyntaxHighlighter.highlightLine(line.text, language: lang))
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
            } else {
                Text(line.text)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(textColor(for: line.kind))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
        .background(rowBackground(for: line.kind))
    }

    private struct NumberedDiffLine {
        let line: DiffLine
        let oldLine: Int?
        let newLine: Int?
    }

    private func makeNumberedLines(_ lines: [DiffLine]) -> [NumberedDiffLine] {
        var oldNumber = 1
        var newNumber = 1
        var numbered: [NumberedDiffLine] = []
        numbered.reserveCapacity(lines.count)

        for line in lines {
            switch line.kind {
            case .context:
                numbered.append(NumberedDiffLine(line: line, oldLine: oldNumber, newLine: newNumber))
                oldNumber += 1
                newNumber += 1
            case .removed:
                numbered.append(NumberedDiffLine(line: line, oldLine: oldNumber, newLine: nil))
                oldNumber += 1
            case .added:
                numbered.append(NumberedDiffLine(line: line, oldLine: nil, newLine: newNumber))
                newNumber += 1
            }
        }

        return numbered
    }

    private func accentColor(for kind: DiffLine.Kind) -> Color {
        switch kind {
        case .added: return theme.diff.addedAccent
        case .removed: return theme.diff.removedAccent
        case .context: return .clear
        }
    }

    private func prefixColor(for kind: DiffLine.Kind) -> Color {
        switch kind {
        case .added: return theme.diff.addedAccent
        case .removed: return theme.diff.removedAccent
        case .context: return theme.text.tertiary
        }
    }

    private func textColor(for kind: DiffLine.Kind) -> Color {
        switch kind {
        case .added, .removed: return theme.text.primary
        case .context: return theme.diff.contextFg
        }
    }

    private func rowBackground(for kind: DiffLine.Kind) -> Color {
        switch kind {
        case .added: return theme.diff.addedBg
        case .removed: return theme.diff.removedBg
        case .context: return .clear
        }
    }
}

// MARK: - Copy Icon Button

private struct CopyIconButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            UIPasteboard.general.string = text
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(2))
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .foregroundStyle(.tokyoFgDim)
        }
    }
}
