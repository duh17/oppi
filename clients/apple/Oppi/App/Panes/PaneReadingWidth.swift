import UIKit

/// What a pane shows beside its neighbour, as its width is decided. Every
/// opener of an attached leaf names one; none names widths of its own except
/// an extension panel, whose surface sends them.
enum PaneContentRole: Equatable {
    /// A document to read (a file, a chat's reader, a commit's diff): it opens
    /// at its reading width.
    case reader
    /// A list or inspector beside a screen (Files, Git, Outline, Context).
    case list
    /// A list beside a reader (a review's file list beside its diff): narrow,
    /// so the reader keeps its reading width.
    case listBesideReader
    /// Widths an extension surface asked for (`ExtensionPanelSnapshot.widths`).
    case custom(PaneCompanionWidths)
}

/// The one owner of how wide a pane opens: a reader beside a list or a chat
/// gets the width that shows the reader's whole prose column
/// (`ReaderReadingColumn.paneWidth`, about 75 characters at the reader's text
/// size), and its neighbour the rest, never below the neighbour's minimum.
/// Where the two do not fit at their minimums the fit rule shows the reader
/// over its neighbour, which stays a strip (`PaneWidthPolicy.fitsBeside`):
/// the iPad mini in portrait, or in landscape with the sidebar showing.
@MainActor
enum PaneReadingWidth {
    /// The reading width at the reader's current text size: the Markdown
    /// reader's text scale over the body font, as its column is drawn.
    static var reader: CGFloat {
        let scale = FullScreenReaderPreferencesStore.shared.preferences(for: .markdown).textScale
        return ReaderReadingColumn(proseFontSize: AppFont.messageBody.pointSize * scale).paneWidth
    }

    /// The widths an attached leaf showing `role` asks its host for. A reader
    /// and a list are never narrower than an iPhone (`PaneMinimumSize.attached`).
    static func widths(for role: PaneContentRole) -> PaneCompanionWidths {
        let minimum = PaneMinimumSize.attached.width
        switch role {
        case .reader:
            let reading = reader
            return PaneCompanionWidths(minimum: minimum, ideal: reading, maximum: max(820, reading))
        case .list:
            return PaneCompanionWidths(minimum: minimum, ideal: 400, maximum: 640)
        case .listBesideReader:
            return PaneCompanionWidths(minimum: 240, ideal: 300, maximum: nil)
        case .custom(let widths):
            return widths
        }
    }

    /// The share of a row a reader opened beside a pane takes, so it reads at
    /// its reading width and its neighbour keeps the rest, at least
    /// `neighbourMinimum`. `width` is the cell the two will share.
    static func splitShare(of width: CGFloat, neighbourMinimum: CGFloat) -> Double? {
        let room = width - PanePresentation.dividerThickness
        guard room > 0 else { return nil }
        let readerWidth = min(reader, room - neighbourMinimum)
        guard readerWidth > 0 else { return nil }
        return Double(readerWidth / room)
    }
}
