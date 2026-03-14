import SwiftUI

/// Inline annotation card rendered between diff lines.
///
/// Shows author icon, severity badge, body text, and resolution state.
/// Designed for interleaving within a diff view, not as a standalone list item.
struct DiffAnnotationCardView: View {
    let annotation: DiffAnnotation
    var onAccept: (() -> Void)?
    var onReject: (() -> Void)?
    var onDelete: (() -> Void)?

    @Environment(\.theme) private var theme
    @State private var dragOffset: CGFloat = 0
    @State private var isExpanded = true

    private var isResolved: Bool { annotation.resolution.isResolved }
    private var isPending: Bool { annotation.resolution.isPending }

    private var authorColor: Color {
        annotation.author.isAgent ? theme.accent.blue : theme.accent.green
    }

    private var severityColor: Color {
        guard let severity = annotation.severity else { return theme.text.secondary }
        switch severity {
        case .error: return theme.accent.red
        case .warn: return theme.accent.orange
        case .info: return theme.accent.blue
        }
    }

    private var resolutionColor: Color {
        switch annotation.resolution {
        case .pending: return theme.text.tertiary
        case .accepted: return theme.accent.green
        case .rejected: return theme.accent.red
        }
    }

    var body: some View {
        cardContent
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            }
            .contextMenu { contextMenuItems }
            .offset(x: dragOffset)
            .background(alignment: .leading) { swipeBackground }
            .gesture(swipeGesture)
            .animation(.easeOut(duration: 0.2), value: dragOffset)
            .onAppear {
                // Resolved annotations start collapsed
                isExpanded = !isResolved
            }
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header: author + severity + resolution
            HStack(spacing: 6) {
                Image(systemName: annotation.author.iconName)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(authorColor)

                Text(annotation.author.displayLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(authorColor)

                if let severity = annotation.severity {
                    HStack(spacing: 3) {
                        Image(systemName: severity.iconName)
                            .font(.system(size: 9))
                        Text(severity.displayLabel)
                            .font(.caption2.weight(.medium))
                            .textCase(.uppercase)
                    }
                    .foregroundStyle(severityColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(severityColor.opacity(0.12), in: Capsule())
                }

                Spacer()

                resolutionBadge
            }

            // Body — collapsed when resolved and tapped shut
            if isExpanded {
                Text(annotation.body)
                    .font(.callout)
                    .foregroundStyle(isResolved ? theme.text.tertiary : theme.text.primary)
                    .fixedSize(horizontal: false, vertical: true)

                if let attachments = annotation.attachments, !attachments.isEmpty {
                    attachmentStrip(attachments)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(severityColor)
                .frame(width: 3)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Context Menu

    @ViewBuilder
    private var contextMenuItems: some View {
        if isPending {
            Button {
                onAccept?()
            } label: {
                Label("Accept", systemImage: "checkmark.circle")
            }

            Button(role: .destructive) {
                onReject?()
            } label: {
                Label("Reject", systemImage: "xmark.circle")
            }
        } else {
            Button {
                // Reset to pending
                onAccept?()
            } label: {
                Label("Reopen", systemImage: "arrow.uturn.backward")
            }
        }

        if annotation.author.isHuman {
            Divider()
            Button(role: .destructive) {
                onDelete?()
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    // MARK: - Swipe Gesture

    /// Swipe background indicators shown behind the card during drag.
    @ViewBuilder
    private var swipeBackground: some View {
        if isPending {
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    // Accept (swipe right → green background on left)
                    if dragOffset > 0 {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.title3)
                                .foregroundStyle(.white)
                            Spacer()
                        }
                        .padding(.leading, 16)
                        .frame(width: dragOffset, height: geometry.size.height)
                        .background(theme.accent.green)
                    }

                    Spacer()

                    // Reject (swipe left → red background on right)
                    if dragOffset < 0 {
                        HStack {
                            Spacer()
                            Image(systemName: "xmark.circle.fill")
                                .font(.title3)
                                .foregroundStyle(.white)
                        }
                        .padding(.trailing, 16)
                        .frame(width: -dragOffset, height: geometry.size.height)
                        .background(theme.accent.red)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                guard isPending else { return }
                dragOffset = value.translation.width
            }
            .onEnded { value in
                guard isPending else { return }
                let threshold: CGFloat = 80

                if value.translation.width > threshold {
                    onAccept?()
                } else if value.translation.width < -threshold {
                    onReject?()
                }

                withAnimation(.easeOut(duration: 0.2)) {
                    dragOffset = 0
                }
            }
    }

    private var cardBackground: Color {
        if isResolved {
            return theme.bg.secondary.opacity(0.5)
        }
        return severityColor.opacity(0.06)
    }

    @ViewBuilder
    private var resolutionBadge: some View {
        switch annotation.resolution {
        case .pending:
            Text("Pending")
                .font(.caption2)
                .foregroundStyle(theme.text.tertiary)
        case .accepted:
            Label("Accepted", systemImage: "checkmark.circle.fill")
                .font(.caption2.weight(.medium))
                .foregroundStyle(theme.accent.green)
        case .rejected:
            Label("Rejected", systemImage: "xmark.circle.fill")
                .font(.caption2.weight(.medium))
                .foregroundStyle(theme.accent.red)
        }
    }

    private func attachmentStrip(_ attachments: [AnnotationImageAttachment]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(attachments.enumerated()), id: \.offset) { _, attachment in
                    if let imageData = Data(base64Encoded: attachment.data),
                       let uiImage = UIImage(data: imageData) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 48, height: 48)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
        }
    }
}
