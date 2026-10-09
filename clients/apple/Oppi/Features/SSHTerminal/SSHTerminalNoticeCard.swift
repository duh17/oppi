import SwiftUI

/// Floating notice over the top of the terminal grid: a blocked program or a
/// one-shot notification.
///
/// It is a material card, not a dialog and not a row of the grid: the headline
/// and host are Oppi's, and the program's text is a separate line, so a host
/// cannot dress its message up as Oppi's. Floating keeps the grid's row count
/// stable, so a notice does not resize the remote PTY. A tap or an upward
/// swipe folds it into the toolbar glyph, so the prompt under it can be read.
struct SSHTerminalNoticeCard: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let notice: SSHTerminalNotice
    let hostLabel: String
    /// The padded card's layout frame, for the collapse anchor.
    let frameChanged: (CGRect) -> Void
    let dismiss: () -> Void

    @State private var drag: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                symbol
                Text(headline)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tint)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Label(SSHTerminalProgramStatusPresentation.hostCaption(hostLabel), systemImage: "network")
                    .font(.caption)
                    .foregroundStyle(.themeComment)
                    .lineLimit(1)
            }
            if !remoteText.isEmpty {
                Text(remoteText)
                    .font(.footnote)
                    .foregroundStyle(.themeFg)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(theme.bg.primary.opacity(0.72))
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.regularMaterial)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(tint, lineWidth: 0.5)
        }
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .offset(y: drag)
        .onTapGesture(perform: dismiss)
        .gesture(swipeUp)
        .padding(.horizontal, 10)
        // The padded card's layout frame. `.offset` above is a render effect
        // inside it, so a drag never changes this frame or writes `cardFrame`.
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }, action: frameChanged)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(headline), \(SSHTerminalProgramStatusPresentation.hostCaption(hostLabel))")
        .accessibilityValue(remoteText)
        .accessibilityAction(named: "Dismiss", dismiss)
        .accessibilityIdentifier(accessibilityID)
    }

    // Each source's copy. A new `SSHTerminalNotice` case adds its arm here.

    @ViewBuilder
    private var symbol: some View {
        switch notice {
        case .blocked(let blocked):
            SSHTerminalStatusGlyph(status: blocked.kind, style: .banner)
        case .alert:
            Image(systemName: "bell.badge")
                .font(.body)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
        }
    }

    /// Oppi's words, never the program's.
    private var headline: String {
        switch notice {
        case .blocked(let blocked): blocked.kind.label
        case .alert: "Notification"
        }
    }

    private var remoteText: String {
        switch notice {
        case .blocked(let blocked): blocked.remoteText
        case .alert(let alert): [alert.title, alert.body].filter { !$0.isEmpty }.joined(separator: ": ")
        }
    }

    private var tint: Color {
        switch notice {
        case .blocked(let blocked): blocked.kind.tint(theme)
        case .alert: .themeBlue
        }
    }

    private var accessibilityID: String {
        switch notice {
        case .blocked: "sshTerminal.programStatusBanner"
        case .alert: "sshTerminal.notificationBanner"
        }
    }

    /// Follows the finger up; downward pull resists. A short lift or an upward
    /// flick dismisses, anything else settles back.
    private var swipeUp: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                let dy = value.translation.height
                drag = dy < 0 ? dy : dy / 6
            }
            .onEnded { value in
                if value.translation.height < -24 || value.predictedEndTranslation.height < -80 {
                    // Settle the offset in the same animation as the removal, so
                    // the card shrinks from where the finger left it into the
                    // glyph rather than toward a point shifted by the drag.
                    withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .smooth) {
                        drag = 0
                        dismiss()
                    }
                } else {
                    withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .smooth) { drag = 0 }
                }
            }
    }

    /// In from the top. Out into the toolbar glyph: the card shrinks toward the
    /// glyph's centre, which sits above it in the bar, whether it was dismissed
    /// or the program moved on. Reduce Motion fades both ways. Applied by the
    /// caller: a transition only counts on the view that is inserted or removed.
    static func transition(card: CGRect, glyph: CGRect, reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .move(edge: .top).combined(with: .opacity),
            removal: .scale(scale: 0.08, anchor: collapseAnchor(card: card, glyph: glyph)).combined(with: .opacity)
        )
    }

    /// The glyph's centre in the card's unit space; y is negative. Before
    /// either frame is known, shrink toward the top edge.
    static func collapseAnchor(card: CGRect, glyph: CGRect) -> UnitPoint {
        guard card.width > 0, card.height > 0, glyph != .zero else { return .top }
        return UnitPoint(x: (glyph.midX - card.minX) / card.width, y: (glyph.midY - card.minY) / card.height)
    }
}
