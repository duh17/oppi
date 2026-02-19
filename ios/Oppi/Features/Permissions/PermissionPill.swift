import LocalAuthentication
import SwiftUI

/// Floating glass pill showing the current pending permission request.
///
/// Single pending: swipe right to allow, left to deny.
/// Multiple pending: swipe disabled, shows "+N more" badge. Tap to open sheet.
/// Critical risk: swipe-to-allow disabled (must use detail sheet).
struct PermissionPill: View {
    let request: PermissionRequest
    let totalCount: Int
    let onAllow: () -> Void
    let onDeny: () -> Void
    let onTap: () -> Void

    @GestureState private var dragOffset: CGFloat = 0
    @State private var isResolving = false
    @State private var resolveFlashColor: Color?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isSinglePending: Bool { totalCount == 1 }
    /// Swipe-to-allow disabled when biometric is required (must use sheet → Face ID).
    private var canSwipeAllow: Bool {
        isSinglePending
        && request.risk != .critical
        && !BiometricService.shared.requiresBiometric(for: request.risk)
    }
    private var canSwipeDeny: Bool { isSinglePending }
    private var riskColor: Color { Color.riskColor(request.risk) }

    private var biometricPillIcon: String {
        switch LAContext().biometryType {
        case .faceID: return "faceid"
        case .touchID: return "touchid"
        case .opticID: return "opticid"
        @unknown default: return "lock.fill"
        }
    }

    private let swipeThreshold: CGFloat = 80
    private let hintThreshold: CGFloat = 40

    /// Whether the display summary indicates a web-browser skill command.
    private var isBrowserCommand: Bool {
        let s = request.displaySummary
        return s.hasPrefix("Navigate:") || s.hasPrefix("JS:") ||
               s.hasPrefix("Screenshot") || s.hasPrefix("Start Chrome") ||
               s.hasPrefix("Dismiss cookies") || s.hasPrefix("Browser:")
    }

    /// SF Symbol for the browser command type.
    private var browserIcon: String {
        let s = request.displaySummary
        if s.hasPrefix("Navigate:") { return "safari" }
        if s.hasPrefix("JS:") { return "curlybraces" }
        if s.hasPrefix("Screenshot") { return "camera.viewfinder" }
        return "globe"
    }

    var body: some View {
        pillContent
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(pillBackground)
            .clipShape(.capsule(style: .continuous))
            .overlay {
                if let flash = resolveFlashColor {
                    Capsule(style: .continuous)
                        .fill(flash.opacity(0.3))
                        .allowsHitTesting(false)
                }
            }
            .offset(x: isResolving ? resolveSlideOffset : dragOffset)
            .opacity(isResolving ? 0 : 1)
            .gesture(swipeGesture)
            .onTapGesture(perform: onTap)
            .sensoryFeedback(.selection, trigger: dragOffset != 0)
            .animation(.snappy(duration: 0.3), value: dragOffset)
            .animation(.easeOut(duration: 0.25), value: isResolving)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint(accessibilityHint)
    }

    // MARK: - Content

    @ViewBuilder
    private var pillContent: some View {
        HStack(spacing: 8) {
            // Swipe hint labels (fade in during drag)
            if canSwipeDeny && dragOffset < -hintThreshold {
                Text("Deny")
                    .font(.caption.bold())
                    .foregroundStyle(.themeRed)
                    .transition(.opacity)
            }

            // Risk icon
            Image(systemName: request.risk.systemImage)
                .font(.subheadline.bold())
                .foregroundStyle(riskColor)

            // Tool context icon (browser gets a globe, others skip)
            if isBrowserCommand {
                Image(systemName: browserIcon)
                    .font(.caption)
                    .foregroundStyle(.themeComment)
            }

            // Command summary
            Text(request.displaySummary)
                .font(.caption.monospaced())
                .foregroundStyle(.themeFg)
                .lineLimit(1)

            Spacer(minLength: 4)

            // Countdown / expiry label
            if request.hasExpiry {
                Text(request.timeoutAt, style: .timer)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.themeComment)
            } else {
                Label("No expiry", systemImage: "infinity")
                    .font(.caption2)
                    .foregroundStyle(.themeComment)
            }

            // Multi-pending badge
            if totalCount > 1 {
                Text("+\(totalCount - 1)")
                    .font(.caption2.bold())
                    .foregroundStyle(.themeFg)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.themeComment.opacity(0.3))
                    .clipShape(Capsule())
            }

            // Biometric lock icon (no swipe-to-allow for gated risks)
            if BiometricService.shared.requiresBiometric(for: request.risk) && isSinglePending {
                Image(systemName: biometricPillIcon)
                    .font(.caption2)
                    .foregroundStyle(.themeComment)
            }

            // Allow hint
            if canSwipeAllow && dragOffset > hintThreshold {
                Text("Allow")
                    .font(.caption.bold())
                    .foregroundStyle(.themeGreen)
                    .transition(.opacity)
            }
        }
    }

    // MARK: - Background

    @ViewBuilder
    private var pillBackground: some View {
        // Tint shifts during drag to hint at the action
        let greenBlend = canSwipeAllow ? max(0, dragOffset / swipeThreshold) : 0
        let redBlend = canSwipeDeny ? max(0, -dragOffset / swipeThreshold) : 0

        RoundedRectangle(cornerRadius: 26)
            .fill(
                Color.themeBgHighlight
                    .opacity(1 - greenBlend * 0.3 - redBlend * 0.3)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 26)
                    .fill(Color.themeGreen.opacity(greenBlend * 0.25))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 26)
                    .fill(Color.themeRed.opacity(redBlend * 0.25))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(riskColor.opacity(0.4), lineWidth: 1)
            )
    }

    // MARK: - Gesture

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .updating($dragOffset) { value, state, _ in
                guard !reduceMotion else { return }
                let dx = value.translation.width
                if dx > 0 && !canSwipeAllow {
                    state = 0
                } else if dx < 0 && !canSwipeDeny {
                    state = 0
                } else {
                    // Rubber-band past threshold
                    state = dx
                }
            }
            .onEnded { value in
                guard !reduceMotion else { return }
                let dx = value.translation.width
                if dx > swipeThreshold && canSwipeAllow {
                    resolveWithFlash(.themeGreen, slideRight: true, action: onAllow)
                } else if dx < -swipeThreshold && canSwipeDeny {
                    resolveWithFlash(.themeRed, slideRight: false, action: onDeny)
                }
            }
    }

    private func resolveWithFlash(_ color: Color, slideRight: Bool, action: @escaping () -> Void) {
        resolveFlashColor = color
        isResolving = true
        resolveSlideDirection = slideRight

        // Fire haptic
        let style: UIImpactFeedbackGenerator.FeedbackStyle = slideRight ? .light : .heavy
        UIImpactFeedbackGenerator(style: style).impactOccurred()

        // Delay action slightly for visual feedback
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            action()
        }
    }

    @State private var resolveSlideDirection = true

    private var resolveSlideOffset: CGFloat {
        resolveSlideDirection ? 300 : -300
    }

    // MARK: - Accessibility

    private var accessibilityLabel: String {
        "Permission request: \(request.tool) \(request.displaySummary)"
    }

    private var accessibilityHint: String {
        if isSinglePending && request.risk != .critical {
            "Swipe right to allow, left to deny, or double tap for details"
        } else {
            "Double tap for details"
        }
    }
}
