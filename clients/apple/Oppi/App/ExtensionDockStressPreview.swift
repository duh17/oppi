#if DEBUG
import SwiftUI
import UIKit

/// A screenshot-only prototype for the extension/composer containment pass.
///
/// This view intentionally does not drive production chat behavior. It recreates
/// the stress state from a live mobile session: expanded goal widget, agent
/// widget, multiple image attachments, focused composer, and keyboard pressure.
struct ExtensionDockStressPreview: View {
    @State private var draft = "look like for our current session\nit looks okay but things are going out of bound here and there lol"
    @State private var isComposerFocused = false
    @State private var showGoalDetail = false

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                Color.themeBg
                    .ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 12) {
                        ExtensionDockStressTranscriptCard(
                            title: "get_subagent_result",
                            subtitle: "wait: true, agent_id: 51e6b21b…",
                            symbol: "checkmark.circle.fill",
                            color: .themeGreen
                        )
                        ExtensionDockStressTranscriptCard(
                            title: "get_subagent_result",
                            subtitle: "agent_id: c7413d8e…",
                            symbol: "checkmark.circle.fill",
                            color: .themeGreen
                        )
                        ExtensionDockStressWorkingRow()
                        Spacer(minLength: 260)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 118)
                    .padding(.bottom, 360)
                }

                ExtensionDockStressNavigationBar()
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ExtensionDockStressBottomRegion(
                    draft: $draft,
                    isComposerFocused: $isComposerFocused,
                    maxExtensionHeight: extensionRegionMaxHeight(screenHeight: proxy.size.height),
                    onOpenGoalDetail: {
                        isComposerFocused = false
                        showGoalDetail = true
                    }
                )
            }
            .task {
                try? await Task.sleep(for: .milliseconds(550))
                isComposerFocused = true
            }
        }
        .sheet(isPresented: $showGoalDetail) {
            ExtensionDockGoalDetailSheet()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(28)
        }
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("screenshot.ready")
    }

    private func extensionRegionMaxHeight(screenHeight: CGFloat) -> CGFloat {
        let proportional = screenHeight * 0.34
        return min(270, max(168, proportional))
    }
}

/// Recreates the live pi-review duplicate-status case using production
/// ExtensionSurfacePanel rendering. The status and widget share the same key,
/// but the widget is below the composer, matching the screenshot state.
struct ExtensionDockReviewCombinedPreview: View {
    @State private var draft = ""
    @State private var isComposerFocused = false

    var body: some View {
        ZStack(alignment: .top) {
            Color.themeBg
                .ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    ExtensionDockStressTranscriptCard(
                        title: "shared/pi/extensions/src/types.ts:1-220",
                        subtitle: "search result · TypeScript",
                        symbol: "checkmark.circle.fill",
                        color: .themeGreen
                    )
                    ExtensionDockStressWorkingRow()
                    Spacer(minLength: 360)
                }
                .padding(.horizontal, 16)
                .padding(.top, 118)
                .padding(.bottom, 340)
            }

            ExtensionDockStressNavigationBar()
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ExtensionDockReviewCombinedBottomRegion(
                draft: $draft,
                isComposerFocused: $isComposerFocused
            )
        }
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("screenshot.ready")
    }
}

private struct ExtensionDockReviewCombinedBottomRegion: View {
    @Binding var draft: String
    @Binding var isComposerFocused: Bool

    private static let reviewSurface = ExtensionSurfaceState(
        statuses: ["pi-review": "Pi review open"],
        widgets: [
            "pi-review": ExtensionWidgetState(
                key: "pi-review",
                lines: [
                    "Pi review open 95 files",
                    "Pi review — vs origin/main — use the native window",
                    "Inline comment: Send now → active session, Stash",
                ],
                placement: "belowEditor"
            ),
        ]
    )

    var body: some View {
        VStack(spacing: 8) {
            ExtensionSurfacePanel(surface: Self.reviewSurface, placement: .aboveEditor)
            ExtensionDockComposerPrototype(draft: $draft, isFocused: $isComposerFocused)
            ExtensionSurfacePanel(surface: Self.reviewSurface, placement: .belowEditor)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(alignment: .top) {
            LinearGradient(
                colors: [Color.themeBg.opacity(0), Color.themeBg.opacity(0.72), Color.themeBg.opacity(0.96)],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)
        }
    }
}

private struct ExtensionDockStressNavigationBar: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button {} label: {
                    Image(systemName: "chevron.left")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.themeFg)
                        .frame(width: 54, height: 54)
                        .glassEffect(.regular, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityHidden(true)

                VStack(spacing: 1) {
                    HStack(spacing: 6) {
                        Text("Review Extension Usa…")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.themeFg)
                            .lineLimit(1)
                        Text("$0.55")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.themeComment)
                    }
                }
                .frame(maxWidth: .infinity)

                HStack(spacing: 10) {
                    Image(systemName: "list.bullet")
                        .font(.headline)
                    ZStack {
                        Circle()
                            .stroke(Color.themeComment.opacity(0.38), lineWidth: 3)
                        Circle()
                            .trim(from: 0, to: 0.78)
                            .stroke(Color.themeGreen, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Text("11")
                            .font(.caption2.monospacedDigit().weight(.semibold))
                    }
                    .frame(width: 34, height: 34)
                }
                .foregroundStyle(.themeFg)
                .padding(.horizontal, 14)
                .frame(height: 54)
                .glassEffect(.regular, in: Capsule())
                .accessibilityHidden(true)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 10)
        }
        .background {
            LinearGradient(
                colors: [Color.themeBg.opacity(0.96), Color.themeBg.opacity(0.72), Color.themeBg.opacity(0)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .top)
        }
    }
}

private struct ExtensionDockStressTranscriptCard: View {
    let title: String
    let subtitle: String
    let symbol: String
    let color: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.caption.weight(.bold))
                .foregroundStyle(color)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.monospaced().weight(.semibold))
                    .foregroundStyle(.themeCyan)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption.monospaced())
                    .foregroundStyle(.themeComment)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.themeBgDark.opacity(0.58), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(Color.themeComment.opacity(0.18), lineWidth: 1)
        }
    }
}

private struct ExtensionDockStressWorkingRow: View {
    var body: some View {
        HStack(spacing: 8) {
            WorkingSpinnerView(tintColor: .themeComment.opacity(0.9), style: .brailleDots)
                .frame(width: 16, height: 16)
            Text("Working…")
                .font(.title3.weight(.medium))
                .foregroundStyle(.themeComment.opacity(0.78))
        }
        .padding(.top, 10)
        .padding(.leading, 18)
    }
}

private struct ExtensionDockStressBottomRegion: View {
    @Binding var draft: String
    @Binding var isComposerFocused: Bool
    let maxExtensionHeight: CGFloat
    let onOpenGoalDetail: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            ExtensionDockGoalCard(onTap: onOpenGoalDetail)
            ExtensionDockAgentsSummaryCard()
            ExtensionDockComposerPrototype(draft: $draft, isFocused: $isComposerFocused)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(alignment: .top) {
            LinearGradient(
                colors: [Color.themeBg.opacity(0), Color.themeBg.opacity(0.72), Color.themeBg.opacity(0.96)],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)
        }
    }
}

private struct ExtensionDockGoalCard: View {
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Audit Oppi extension surfaces")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.themeFg)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        Text("1 of 5 · Review backlog")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.themeComment)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    ExtensionDockPill(text: "1 active", systemImage: "play.circle.fill", tint: .themeBlue)
                    Image(systemName: "chevron.up")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.themeComment)
                        .frame(width: 28, height: 28)
                        .background(Color.themeFg.opacity(0.06), in: Circle())
                }

                Capsule()
                    .fill(Color.themeFg.opacity(0.10))
                    .frame(height: 4)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(Color.themeFg.opacity(0.68))
                            .frame(width: 72, height: 4)
                    }
            }
            .frame(minHeight: 58)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.themeFg.opacity(0.12), lineWidth: 0.5)
            }
            .shadow(color: Color.black.opacity(0.08), radius: 10, x: 0, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("extensionDockStress.goalCard")
        .accessibilityLabel("Open goal details")
        .accessibilityHint("Shows the full extension checklist in a sheet")
    }
}

struct ExtensionDockGoalDetailStandalonePreview: View {
    var body: some View {
        ExtensionDockGoalDetailSheet()
            .accessibilityIdentifier("screenshot.ready")
    }
}

private struct ExtensionDockGoalDetailSheet: View {
    @Environment(\.dismiss) private var dismiss

    private let tasks: [ExtensionDockTask] = [
        .init(number: 1, title: "Review current backlog and extension-related notes", state: .running),
        .init(number: 2, title: "Map extension surfaces in the iOS app and server docs", state: .waiting),
        .init(number: 3, title: "Audit surfaces against Apple HIG/native iOS patterns", state: .waiting),
        .init(number: 4, title: "Identify unification opportunities and priority improvements", state: .waiting),
        .init(number: 5, title: "Draft a focused implementation/research plan", state: .waiting),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Audit Oppi extension surfaces")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.themeFg)
                            .accessibilityIdentifier("extensionDockStress.goalDetail.title")

                        Text("Full checklist opens away from the composer, so the keyboard state stays compact and predictable.")
                            .font(.caption)
                            .foregroundStyle(.themeComment)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Capsule()
                        .fill(Color.themeFg.opacity(0.10))
                        .frame(height: 6)
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(Color.themeFg.opacity(0.70))
                                .frame(width: 92, height: 6)
                        }
                        .padding(.vertical, 2)

                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(tasks) { task in
                            ExtensionDockTaskRow(task: task)
                        }
                    }
                }
                .padding(20)
            }
            .background(Color.themeBg.ignoresSafeArea())
            .navigationTitle("Goal details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct ExtensionDockAgentsSummaryCard: View {
    var body: some View {
        HStack(spacing: 10) {
            Text("3 agents · 2 done · 1 mapping iOS surfaces")
                .font(.subheadline.monospaced().weight(.semibold))
                .foregroundStyle(.themeFg)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            ExtensionDockPill(text: "82 tools", systemImage: nil, tint: .themeComment)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.themeComment)
                .frame(width: 28, height: 28)
                .background(Color.themeFg.opacity(0.06), in: Circle())
        }
        .frame(minHeight: 48)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.themeFg.opacity(0.12), lineWidth: 0.5)
        }
        .shadow(color: Color.black.opacity(0.08), radius: 10, x: 0, y: 2)
    }
}

private struct ExtensionDockPill: View {
    let text: String
    let systemImage: String?
    let tint: Color

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.caption2.weight(.bold))
            }
            Text(text)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.themeBgHighlight.opacity(0.72), in: Capsule())
    }
}

private struct ExtensionDockTask: Identifiable {
    enum State {
        case running
        case waiting
    }

    let number: Int
    let title: String
    let state: State

    var id: Int { number }
}

private struct ExtensionDockTaskRow: View {
    let task: ExtensionDockTask

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: task.state == .running ? "play.circle.fill" : "circle")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(task.state == .running ? Color.themeBlue : Color.themeComment)
                .frame(width: 22, height: 22)
                .padding(.top, 1)

            Text("\(task.number). \(task.title)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.themeFg)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(minHeight: 44, alignment: .center)
        .background(
            task.state == .running ? Color.themeFg.opacity(0.055) : Color.clear,
            in: RoundedRectangle(cornerRadius: 13, style: .continuous)
        )
        .overlay {
            if task.state == .running {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(Color.themeComment.opacity(0.16), lineWidth: 1)
            }
        }
    }
}

private struct ExtensionDockComposerPrototype: View {
    @Binding var draft: String
    @Binding var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(1...3, id: \.self) { index in
                        ExtensionDockAttachmentThumbnail(index: index)
                    }
                }
                .padding(.horizontal, 2)
                .padding(.top, 2)
                .padding(.bottom, 1)
            }
            .accessibilityHidden(true)

            HStack(alignment: .bottom, spacing: 12) {
                Circle()
                    .fill(Color.themeBgDark.opacity(0.76))
                    .overlay {
                        Image(systemName: "mic")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(.themeFg)
                    }
                    .overlay {
                        Circle().stroke(Color.themeComment.opacity(0.35), lineWidth: 1)
                    }
                    .frame(width: 52, height: 52)
                    .accessibilityHidden(true)

                ExtensionDockPreviewTextView(text: $draft, isFirstResponder: $isFocused)
                    .frame(width: 220, height: 72, alignment: .leading)
                    .clipped()

                Button {} label: {
                    Image(systemName: "arrow.up")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 52, height: 52)
                        .background(Color.themePurple, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityHidden(true)
            }

        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 10)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.themeFg.opacity(0.12), lineWidth: 0.5)
        }
        .shadow(color: Color.black.opacity(0.14), radius: 14, x: 0, y: 4)
    }
}

private struct ExtensionDockPreviewTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFirstResponder: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.backgroundColor = .clear
        textView.textColor = UIColor(Color.themeFg)
        textView.tintColor = UIColor(Color.themeBlue)
        textView.font = .preferredFont(forTextStyle: .title2)
        textView.adjustsFontForContentSizeCategory = true
        textView.isScrollEnabled = false
        textView.textContainerInset = UIEdgeInsets(top: 3, left: 0, bottom: 3, right: 0)
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainer.widthTracksTextView = true
        textView.autocorrectionType = .no
        textView.spellCheckingType = .no
        textView.autocapitalizationType = .none
        textView.smartDashesType = .no
        textView.smartQuotesType = .no
        textView.returnKeyType = .default
        textView.delegate = context.coordinator
        textView.accessibilityIdentifier = "extensionDockStress.input"
        textView.inputAssistantItem.leadingBarButtonGroups = []
        textView.inputAssistantItem.trailingBarButtonGroups = []
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.text = $text
        if textView.text != text {
            textView.text = text
        }
        if isFirstResponder, !textView.isFirstResponder {
            DispatchQueue.main.async {
                textView.becomeFirstResponder()
            }
        } else if !isFirstResponder, textView.isFirstResponder {
            textView.resignFirstResponder()
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textViewDidChange(_ textView: UITextView) {
            text.wrappedValue = textView.text
        }

        func textViewDidBeginEditing(_: UITextView) {}
        func textViewDidEndEditing(_: UITextView) {}
    }
}

private struct ExtensionDockAttachmentThumbnail: View {
    let index: Int

    var body: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.themeBgDark, Color.themeCyan.opacity(0.28), Color.themePurple.opacity(0.22)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(alignment: .bottomLeading) {
                    Text("img \(index)")
                        .font(.caption2.monospaced().weight(.semibold))
                        .foregroundStyle(.themeFg)
                        .padding(6)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.themeComment.opacity(0.25), lineWidth: 1)
                }

            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 17, weight: .semibold))
                .symbolRenderingMode(.palette)
                .foregroundStyle(Color.themeFg, Color.themeBgDark.opacity(0.92))
                .padding(3)
        }
        .frame(width: 64, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct ExtensionDockComposerChip: View {
    let systemImage: String?
    let text: String?

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.caption.weight(.bold))
            }
            if let text {
                Text(text)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }
        }
        .foregroundStyle(.themeFg)
        .padding(.horizontal, text == nil ? 13 : 11)
        .padding(.vertical, 7)
        .glassEffect(.regular, in: Capsule())
    }
}
#endif
