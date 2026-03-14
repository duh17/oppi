import SwiftUI

/// A diff view that interleaves inline annotation cards between diff hunks.
///
/// Splits the hunk list at annotation boundaries and renders each segment
/// as a `UnifiedDiffView` text block with annotation cards inserted after
/// the lines they reference.
///
/// When no annotations are present, renders the standard `UnifiedDiffView`.
struct AnnotatedDiffView: View {
    let hunks: [WorkspaceReviewDiffHunk]
    let filePath: String
    let annotations: [DiffAnnotation]
    var onLineTap: ((DiffLineTapInfo) -> Void)?
    var onAccept: ((DiffAnnotation) -> Void)?
    var onReject: ((DiffAnnotation) -> Void)?
    var onDelete: ((DiffAnnotation) -> Void)?

    @Environment(\.theme) private var theme

    var body: some View {
        if hunks.isEmpty {
            ContentUnavailableView(
                "No Textual Changes",
                systemImage: "checkmark.circle",
                description: Text("This diff has no textual changes to show.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.themeBgDark)
        } else if annotations.isEmpty {
            // Fast path: no annotations, use the proven single-pass renderer
            UnifiedDiffView(hunks: hunks, filePath: filePath)
        } else {
            annotatedContent
        }
    }

    private var annotatedContent: some View {
        let segments = buildSegments()

        return ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(segments) { segment in
                    switch segment.kind {
                    case .diffLines(let segmentHunks):
                        UnifiedDiffTextSegment(
                            hunks: segmentHunks,
                            filePath: filePath,
                            onLineTap: onLineTap
                        )

                    case .annotation(let annotation):
                        DiffAnnotationCardView(
                            annotation: annotation,
                            onAccept: onAccept.map { cb in { cb(annotation) } },
                            onReject: onReject.map { cb in { cb(annotation) } },
                            onDelete: onDelete.map { cb in { cb(annotation) } }
                        )
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                    }
                }
            }
            .background(Color.themeBgDark)
        }
        .background(Color.themeBgDark)
    }

    // MARK: - Segmentation

    /// Build an ordered list of segments: diff text blocks interleaved with annotation cards.
    ///
    /// For each hunk, we check if any annotations anchor to lines within that hunk.
    /// If so, we split the hunk at the annotation point and insert the annotation card.
    private func buildSegments() -> [DiffSegment] {
        // Build a lookup: newLine -> [annotations] for "new" side,
        // oldLine -> [annotations] for "old" side
        let annotationsByNewLine = Dictionary(
            grouping: annotations.filter { $0.side == .new },
            by: { $0.anchorLine ?? -1 }
        )
        let annotationsByOldLine = Dictionary(
            grouping: annotations.filter { $0.side == .old },
            by: { $0.anchorLine ?? -1 }
        )
        let fileLevelAnnotations = annotations.filter { $0.isFileLevel }

        var segments: [DiffSegment] = []
        var segmentIndex = 0

        // File-level annotations at the top
        for annotation in fileLevelAnnotations {
            segments.append(DiffSegment(
                id: "file-\(segmentIndex)",
                kind: .annotation(annotation)
            ))
            segmentIndex += 1
        }

        for (hunkIndex, hunk) in hunks.enumerated() {
            // Collect annotations that fall within this hunk
            var hunkAnnotations: [(afterLineIndex: Int, annotations: [DiffAnnotation])] = []

            for (lineIndex, line) in hunk.lines.enumerated() {
                var lineAnnotations: [DiffAnnotation] = []

                if let newLine = line.newLine,
                   let matches = annotationsByNewLine[newLine] {
                    lineAnnotations.append(contentsOf: matches)
                }
                if let oldLine = line.oldLine, line.kind == .removed,
                   let matches = annotationsByOldLine[oldLine] {
                    lineAnnotations.append(contentsOf: matches)
                }

                if !lineAnnotations.isEmpty {
                    hunkAnnotations.append((afterLineIndex: lineIndex, annotations: lineAnnotations))
                }
            }

            if hunkAnnotations.isEmpty {
                // No annotations in this hunk — render as a single block
                segments.append(DiffSegment(
                    id: "hunk-\(hunkIndex)",
                    kind: .diffLines([hunk])
                ))
                segmentIndex += 1
            } else {
                // Split hunk at annotation boundaries
                var currentStart = 0

                for entry in hunkAnnotations {
                    let splitIndex = entry.afterLineIndex + 1

                    // Lines before (and including) the annotated line
                    if currentStart < splitIndex {
                        let slice = Array(hunk.lines[currentStart..<splitIndex])
                        let subHunk = makeSubHunk(from: hunk, lines: slice)
                        segments.append(DiffSegment(
                            id: "hunk-\(hunkIndex)-\(segmentIndex)",
                            kind: .diffLines([subHunk])
                        ))
                        segmentIndex += 1
                    }

                    // Annotation cards
                    for annotation in entry.annotations {
                        segments.append(DiffSegment(
                            id: "ann-\(annotation.id)",
                            kind: .annotation(annotation)
                        ))
                        segmentIndex += 1
                    }

                    currentStart = splitIndex
                }

                // Remaining lines after the last annotation
                if currentStart < hunk.lines.count {
                    let slice = Array(hunk.lines[currentStart...])
                    let subHunk = makeSubHunk(from: hunk, lines: slice)
                    segments.append(DiffSegment(
                        id: "hunk-\(hunkIndex)-tail-\(segmentIndex)",
                        kind: .diffLines([subHunk])
                    ))
                    segmentIndex += 1
                }
            }
        }

        return segments
    }

    private func makeSubHunk(
        from original: WorkspaceReviewDiffHunk,
        lines: [WorkspaceReviewDiffLine]
    ) -> WorkspaceReviewDiffHunk {
        let oldNumbers = lines.compactMap(\.oldLine)
        let newNumbers = lines.compactMap(\.newLine)
        return WorkspaceReviewDiffHunk(
            oldStart: oldNumbers.first ?? original.oldStart,
            oldCount: oldNumbers.count,
            newStart: newNumbers.first ?? original.newStart,
            newCount: newNumbers.count,
            lines: lines
        )
    }
}

// MARK: - Segment Model

struct DiffSegment: Identifiable {
    let id: String
    let kind: Kind

    enum Kind {
        case diffLines([WorkspaceReviewDiffHunk])
        case annotation(DiffAnnotation)
    }
}

// MARK: - Diff Text Segment

/// Renders a subset of diff hunks as attributed text without its own scroll view.
/// Used inside the annotated diff's LazyVStack so multiple segments share
/// a single outer scroll container.
private struct UnifiedDiffTextSegment: UIViewRepresentable {
    let hunks: [WorkspaceReviewDiffHunk]
    let filePath: String
    var onLineTap: ((DiffLineTapInfo) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(onLineTap: onLineTap)
    }

    func makeUIView(context: Context) -> UITextView {
        let textStorage = NSTextStorage()
        let layoutManager = UnifiedDiffSegmentLayoutManager()
        let textContainer = NSTextContainer()
        textContainer.lineFragmentPadding = 0
        textContainer.lineBreakMode = .byClipping
        textContainer.widthTracksTextView = false
        textContainer.size = CGSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)

        let textView = UITextView(frame: .zero, textContainer: textContainer)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 2, left: 0, bottom: 2, right: 0)

        let attrText = DiffAttributedStringBuilder.build(hunks: hunks, filePath: filePath)
        textStorage.setAttributedString(attrText)

        // Size to fit content
        let measured = attrText.boundingRect(
            with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin],
            context: nil
        )
        let contentWidth = ceil(measured.width) + 20
        layoutManager.measuredContentWidth = contentWidth

        textView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            textView.widthAnchor.constraint(greaterThanOrEqualToConstant: contentWidth),
        ])

        // Add tap gesture for line-level annotation authoring
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.delegate = context.coordinator
        textView.addGestureRecognizer(tap)

        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        context.coordinator.onLineTap = onLineTap
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = max(proposal.width ?? 300, 300)
        let size = uiView.sizeThatFits(CGSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        return CGSize(width: max(size.width, width), height: size.height)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onLineTap: ((DiffLineTapInfo) -> Void)?

        init(onLineTap: ((DiffLineTapInfo) -> Void)?) {
            self.onLineTap = onLineTap
        }

        /// Only recognize taps in the gutter area (left ~80pt where line numbers live).
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            false
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended,
                  let textView = gesture.view as? UITextView else { return }

            let point = gesture.location(in: textView)

            // Only respond to taps in the gutter area (line numbers)
            guard point.x < 80 else { return }

            let inset = textView.textContainerInset
            let textPoint = CGPoint(x: point.x - inset.left, y: point.y - inset.top)

            let charIndex = textView.layoutManager.characterIndex(
                for: textPoint,
                in: textView.textContainer,
                fractionOfDistanceBetweenInsertionPoints: nil
            )

            guard charIndex < textView.textStorage.length else { return }

            if let tapInfo = textView.textStorage.attribute(
                diffLineTapInfoKey,
                at: charIndex,
                effectiveRange: nil
            ) as? DiffLineTapInfo {
                onLineTap?(tapInfo)
            }
        }
    }
}

/// Layout manager for segments — draws full-width backgrounds like the main diff view.
private final class UnifiedDiffSegmentLayoutManager: NSLayoutManager {
    var measuredContentWidth: CGFloat = 0

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let textStorage, let textContainer = textContainers.first else { return }

        let fillWidth = measuredContentWidth
        let lineKindKey = NSAttributedString.Key("unifiedDiffLineKind")

        let addedBg = UIColor(Color.themeDiffAdded.opacity(0.18))
        let removedBg = UIColor(Color.themeDiffRemoved.opacity(0.15))
        let headerBg = UIColor(Color.themeBgHighlight)

        textStorage.enumerateAttribute(lineKindKey, in: NSRange(location: 0, length: textStorage.length), options: []) { value, attrRange, _ in
            guard let kind = value as? String else { return }
            let bg: UIColor
            switch kind {
            case "added": bg = addedBg
            case "removed": bg = removedBg
            case "header": bg = headerBg
            default: return
            }

            let glyphRange = self.glyphRange(forCharacterRange: attrRange, actualCharacterRange: nil)
            self.enumerateLineFragments(forGlyphRange: glyphRange) { rect, _, _, _, _ in
                var fillRect = rect
                fillRect.origin.x = 0
                fillRect.size.width = fillWidth
                fillRect.origin.x += origin.x
                fillRect.origin.y += origin.y
                bg.setFill()
                UIRectFillUsingBlendMode(fillRect, .normal)
            }
        }
    }
}
