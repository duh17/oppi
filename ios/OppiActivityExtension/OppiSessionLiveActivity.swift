import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

private let liveActivityTransitionAnimation = Animation.easeInOut(duration: 0.22)
private let liveActivityCountAnimation = Animation.easeInOut(duration: 0.18)

/// Aggregate Live Activity + Dynamic Island UI for Oppi sessions.
struct PiSessionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PiSessionAttributes.self) { context in
            LockScreenView(context: context)
                .widgetURL(deepLinkURL(for: context.state))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        PhaseGlyphView(
                            state: context.state,
                            isStale: context.isStale,
                            size: 24
                        )

                        Text(context.state.primarySessionName)
                            .font(.caption.bold())
                            .lineLimit(1)
                            .foregroundStyle(.primary)
                            .animation(
                                liveActivityTransitionAnimation,
                                value: context.state.primarySessionName
                            )
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(accessibilitySummary(context.state, isStale: context.isStale))
                }

                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.pendingApprovalCount > 0 {
                        CounterBadgeView(
                            count: context.state.pendingApprovalCount,
                            phase: .needsApproval,
                            isStale: context.isStale,
                            prefix: "+"
                        )
                    } else {
                        PhaseStatusBadge(
                            label: LiveActivityPresentation.phaseLabel(context.state.primaryPhase),
                            phase: context.state.primaryPhase,
                            isStale: context.isStale
                        )
                    }
                }

                DynamicIslandExpandedRegion(.center) {
                    if context.isStale {
                        StaleStatusView(message: "Update delayed")
                    } else if let summary = context.state.topPermissionSummary,
                              !summary.isEmpty {
                        StatusMessageView(
                            title: "Approval required",
                            message: summary,
                            systemImage: "exclamationmark.shield.fill",
                            phase: .needsApproval,
                            monospacedMessage: true
                        )
                    } else if let activity = LiveActivityPresentation.centerActivityText(context.state) {
                        StatusMessageView(
                            title: nil,
                            message: activity,
                            systemImage: context.state.primaryPhase == .working ? LiveActivityPresentation.primarySymbol(for: context.state) : nil,
                            phase: context.state.primaryPhase,
                            monospacedMessage: false
                        )
                    }
                }

                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            if context.state.pendingApprovalCount == 0,
                               let changeSummary = LiveActivityPresentation.changeStatsSummary(context.state) {
                                ChangeStatsSummaryView(
                                    summary: changeSummary,
                                    phase: context.state.primaryPhase
                                )
                            } else {
                                SecondaryStatusPill(text: LiveActivityPresentation.sessionSummary(context.state))
                            }

                            Spacer(minLength: 8)

                            if !context.isStale,
                               context.state.primaryPhase == .working,
                               let start = context.state.sessionStartDate {
                                TimerPill(start: start, phase: context.state.primaryPhase)
                            }
                        }

                        if let permissionId = context.state.topPermissionId {
                            permissionReviewControls(permissionId: permissionId, isStale: context.isStale)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 6)
                }
            } compactLeading: {
                PhaseGlyphView(
                    state: context.state,
                    isStale: context.isStale,
                    size: 18
                )
                .accessibilityLabel(accessibilitySummary(context.state, isStale: context.isStale))
            } compactTrailing: {
                if context.state.pendingApprovalCount > 0 {
                    CounterBadgeView(
                        count: context.state.pendingApprovalCount,
                        phase: .needsApproval,
                        isStale: context.isStale,
                        prefix: nil
                    )
                    .accessibilityLabel("\(context.state.pendingApprovalCount) pending approvals")
                } else if let badge = compactChangeBadge(context.state) {
                    CompactTrailingBadge(
                        text: badge,
                        phase: context.state.primaryPhase,
                        isStale: context.isStale,
                        monospaced: true
                    )
                    .accessibilityLabel(compactChangeAccessibilityLabel(context.state))
                } else {
                    CompactTrailingBadge(
                        text: LiveActivityPresentation.phaseShortLabel(context.state.primaryPhase),
                        phase: context.state.primaryPhase,
                        isStale: context.isStale,
                        monospaced: false
                    )
                    .accessibilityLabel(LiveActivityPresentation.phaseLabel(context.state.primaryPhase))
                }
            } minimal: {
                PhaseGlyphView(
                    state: context.state,
                    isStale: context.isStale,
                    size: 16
                )
                .accessibilityLabel(accessibilitySummary(context.state, isStale: context.isStale))
            }
        }
    }
}

// MARK: - Lock Screen

private struct LockScreenView: View {
    let context: ActivityViewContext<PiSessionAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                HStack(spacing: 10) {
                    PhaseGlyphView(
                        state: context.state,
                        isStale: context.isStale,
                        size: 34
                    )

                    VStack(alignment: .leading, spacing: 5) {
                        Text(context.state.primarySessionName)
                            .font(.subheadline.bold())
                            .lineLimit(1)

                        if context.isStale {
                            StaleStatusView(message: "Update delayed")
                        } else if let summary = context.state.topPermissionSummary,
                                  !summary.isEmpty {
                            StatusMessageView(
                                title: nil,
                                message: summary,
                                systemImage: "exclamationmark.shield.fill",
                                phase: .needsApproval,
                                monospacedMessage: true
                            )
                        } else if let activity = LiveActivityPresentation.centerActivityText(context.state) {
                            StatusMessageView(
                                title: nil,
                                message: activity,
                                systemImage: context.state.primaryPhase == .working ? LiveActivityPresentation.primarySymbol(for: context.state) : nil,
                                phase: context.state.primaryPhase,
                                monospacedMessage: false
                            )
                        }
                    }
                }

                Spacer(minLength: 12)

                VStack(alignment: .trailing, spacing: 6) {
                    PhaseStatusBadge(
                        label: LiveActivityPresentation.phaseLabel(context.state.primaryPhase),
                        phase: context.state.primaryPhase,
                        isStale: context.isStale
                    )

                    if context.state.pendingApprovalCount > 0 {
                        CounterBadgeView(
                            count: context.state.pendingApprovalCount,
                            phase: .needsApproval,
                            isStale: context.isStale,
                            prefix: nil
                        )
                    } else if let changeSummary = LiveActivityPresentation.changeStatsSummary(context.state) {
                        ChangeStatsSummaryView(
                            summary: changeSummary,
                            phase: context.state.primaryPhase
                        )
                    } else {
                        SecondaryStatusPill(text: LiveActivityPresentation.sessionSummary(context.state))
                    }

                    if !context.isStale,
                       context.state.primaryPhase == .working,
                       let start = context.state.sessionStartDate {
                        TimerPill(start: start, phase: context.state.primaryPhase)
                            .accessibilityLabel("Session timer")
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilitySummary(context.state, isStale: context.isStale))

            if let permissionId = context.state.topPermissionId {
                permissionReviewControls(permissionId: permissionId, isStale: context.isStale)
            }
        }
        .padding(16)
    }
}

private struct PhaseGlyphView: View {
    let state: PiSessionAttributes.ContentState
    let isStale: Bool
    let size: CGFloat

    var body: some View {
        let accent = phaseAccentColor(for: state.primaryPhase, isStale: isStale)

        ZStack {
            RoundedRectangle(cornerRadius: size * 0.38, style: .continuous)
                .fill(phaseBackgroundColor(state.primaryPhase, isStale: isStale))

            RoundedRectangle(cornerRadius: size * 0.38, style: .continuous)
                .strokeBorder(phaseBorderColor(state.primaryPhase, isStale: isStale), lineWidth: 0.9)

            Image(systemName: LiveActivityPresentation.primarySymbol(for: state))
                .font(.system(size: size * 0.56, weight: .semibold))
                .foregroundStyle(accent)
                .symbolEffect(.bounce, value: glyphAnimationToken(state, isStale: isStale))
                .symbolEffect(.pulse, options: .repeating, isActive: shouldPulse(state.primaryPhase) && !isStale)
        }
        .frame(width: size, height: size)
        .shadow(color: accent.opacity(isStale ? 0.0 : 0.22), radius: size * 0.16, y: 1)
        .accessibilityHidden(true)
    }
}

private struct PhaseStatusBadge: View {
    let label: String
    let phase: SessionPhase
    let isStale: Bool

    var body: some View {
        Text(label)
            .font(.caption2.bold())
            .foregroundStyle(phaseAccentColor(for: phase, isStale: isStale))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(phaseBackgroundColor(phase, isStale: isStale)))
            .overlay(
                Capsule().strokeBorder(phaseBorderColor(phase, isStale: isStale), lineWidth: 0.8)
            )
            .animation(liveActivityTransitionAnimation, value: label)
    }
}

private struct CompactTrailingBadge: View {
    let text: String
    let phase: SessionPhase
    let isStale: Bool
    let monospaced: Bool

    var body: some View {
        Group {
            if monospaced {
                Text(text)
                    .font(.caption2.monospacedDigit().bold())
            } else {
                Text(text)
                    .font(.caption2.bold())
            }
        }
        .foregroundStyle(phaseAccentColor(for: phase, isStale: isStale))
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(phaseBackgroundColor(phase, isStale: isStale)))
        .overlay(
            Capsule().strokeBorder(phaseBorderColor(phase, isStale: isStale), lineWidth: 0.75)
        )
        .animation(liveActivityTransitionAnimation, value: text)
    }
}

private struct CounterBadgeView: View {
    let count: Int
    let phase: SessionPhase
    let isStale: Bool
    let prefix: String?

    var body: some View {
        Text("\(prefix ?? "")\(count)")
            .font(.caption2.bold())
            .foregroundStyle(phaseAccentColor(for: phase, isStale: isStale))
            .contentTransition(.numericText())
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(phaseBackgroundColor(phase, isStale: isStale)))
            .overlay(
                Capsule().strokeBorder(phaseBorderColor(phase, isStale: isStale), lineWidth: 0.8)
            )
            .animation(liveActivityCountAnimation, value: count)
    }
}

private struct StatusMessageView: View {
    let title: String?
    let message: String
    let systemImage: String?
    let phase: SessionPhase
    let monospacedMessage: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(phaseAccentColor(for: phase))
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 2) {
                if let title {
                    Text(title)
                        .font(.caption.bold())
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }

                messageView
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(neutralSurfaceColor())
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(neutralSurfaceBorderColor(), lineWidth: 0.8)
        )
        .animation(liveActivityTransitionAnimation, value: message)
    }

    @ViewBuilder
    private var messageView: some View {
        if monospacedMessage {
            Text(message)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else {
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

private struct SecondaryStatusPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Capsule().fill(neutralSurfaceColor()))
            .overlay(
                Capsule().strokeBorder(neutralSurfaceBorderColor(), lineWidth: 0.8)
            )
    }
}

private struct TimerPill: View {
    let start: Date
    let phase: SessionPhase

    var body: some View {
        Text(timerInterval: start...Date.distantFuture, countsDown: false)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(phaseAccentColor(for: phase))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: true)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Capsule().fill(phaseBackgroundColor(phase)))
            .overlay(
                Capsule().strokeBorder(phaseBorderColor(phase), lineWidth: 0.8)
            )
    }
}

private struct PermissionActionButtons: View {
    let permissionId: String

    var body: some View {
        HStack(spacing: 8) {
            Button(intent: DenyPermissionIntent(permissionId: permissionId)) {
                Label("Deny", systemImage: "xmark")
                    .font(.caption2.bold())
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .accessibilityLabel("Deny permission request")

            Button(intent: ApprovePermissionIntent(permissionId: permissionId)) {
                Label("Approve", systemImage: "checkmark")
                    .font(.caption2.bold())
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .accessibilityLabel("Approve permission request")
        }
    }
}

private struct StaleStatusView: View {
    let message: LocalizedStringKey

    var body: some View {
        Label(message, systemImage: "clock.badge.exclamationmark")
            .font(.caption2.bold())
            .foregroundStyle(phaseAccentColor(for: .needsApproval, isStale: true))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Capsule().fill(phaseBackgroundColor(.needsApproval, isStale: true)))
            .overlay(
                Capsule().strokeBorder(phaseBorderColor(.needsApproval, isStale: true), lineWidth: 0.8)
            )
    }
}

private struct OpenAppReviewHint: View {
    var body: some View {
        Label("Open Oppi to review", systemImage: "iphone")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Capsule().fill(neutralSurfaceColor()))
            .overlay(
                Capsule().strokeBorder(neutralSurfaceBorderColor(), lineWidth: 0.8)
            )
            .accessibilityLabel("Open Oppi to review this request")
    }
}

@ViewBuilder
private func permissionReviewControls(permissionId: String, isStale: Bool) -> some View {
    if isStale {
        OpenAppReviewHint()
    } else {
        PermissionActionButtons(permissionId: permissionId)
    }
}

// MARK: - Helpers

private func glyphAnimationToken(_ state: PiSessionAttributes.ContentState, isStale: Bool) -> String {
    [
        state.primaryPhase.rawValue,
        state.primaryTool ?? "",
        state.primarySessionName,
        String(state.pendingApprovalCount),
        isStale ? "stale" : "fresh",
    ].joined(separator: "|")
}

private func compactChangeBadge(_ state: PiSessionAttributes.ContentState) -> String? {
    let mutatingTools = max(state.primaryMutatingToolCalls ?? 0, 0)
    guard mutatingTools > 0 else { return nil }

    let added = max(state.primaryAddedLines ?? 0, 0)
    let removed = max(state.primaryRemovedLines ?? 0, 0)
    let changedLineTotal = added + removed
    if changedLineTotal > 0 {
        return "Δ\(compactCountLabel(changedLineTotal))"
    }

    let filesChanged = max(state.primaryFilesChanged ?? 0, 0)
    if filesChanged > 0 {
        return "F\(compactCountLabel(filesChanged))"
    }

    return "T\(compactCountLabel(mutatingTools))"
}

private struct ChangeStatsSummaryView: View {
    let summary: LiveActivityChangeStatsSummary
    let phase: SessionPhase

    var body: some View {
        HStack(spacing: 6) {
            if summary.filesChanged > 0 {
                Text(fileCountLabel(summary.filesChanged))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text(toolCountLabel(summary.mutatingToolCalls))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if summary.addedLines > 0 {
                Text("+\(summary.addedLines)")
                    .font(.caption2.monospacedDigit().bold())
                    .foregroundStyle(.green)
            }

            if summary.removedLines > 0 {
                Text("-\(summary.removedLines)")
                    .font(.caption2.monospacedDigit().bold())
                    .foregroundStyle(.red)
            }

            if summary.addedLines == 0,
               summary.removedLines == 0,
               summary.filesChanged > 0 {
                Text(toolCountLabel(summary.mutatingToolCalls))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Capsule().fill(phaseBackgroundColor(phase)))
        .overlay(
            Capsule().strokeBorder(phaseBorderColor(phase), lineWidth: 0.8)
        )
    }
}

private func compactChangeAccessibilityLabel(_ state: PiSessionAttributes.ContentState) -> String {
    let mutatingTools = max(state.primaryMutatingToolCalls ?? 0, 0)
    let filesChanged = max(state.primaryFilesChanged ?? 0, 0)
    let added = max(state.primaryAddedLines ?? 0, 0)
    let removed = max(state.primaryRemovedLines ?? 0, 0)

    var parts = [
        mutatingTools == 1 ? "1 mutating tool call" : "\(mutatingTools) mutating tool calls"
    ]

    if filesChanged > 0 {
        parts.append(filesChanged == 1 ? "1 file changed" : "\(filesChanged) files changed")
    }

    if added > 0 || removed > 0 {
        if added > 0 {
            parts.append("\(added) lines added")
        }
        if removed > 0 {
            parts.append("\(removed) lines removed")
        }
    }

    return parts.joined(separator: ", ")
}

private func compactCountLabel(_ value: Int) -> String {
    let clamped = max(0, value)
    if clamped < 1_000 {
        return "\(clamped)"
    }
    if clamped < 1_000_000 {
        return "\(clamped / 1_000)k"
    }
    return "\(clamped / 1_000_000)m"
}

private func fileCountLabel(_ count: Int) -> String {
    count == 1 ? "1 file" : "\(count) files"
}

private func toolCountLabel(_ count: Int) -> String {
    count == 1 ? "1 tool" : "\(count) tools"
}

private func phaseAccentColor(for phase: SessionPhase, isStale: Bool = false) -> Color {
    isStale ? Color(red: 0.97, green: 0.65, blue: 0.24) : LiveActivityPresentation.phaseColor(phase)
}

private func phaseBackgroundColor(_ phase: SessionPhase, isStale: Bool = false) -> Color {
    phaseAccentColor(for: phase, isStale: isStale).opacity(isStale ? 0.18 : 0.16)
}

private func phaseBorderColor(_ phase: SessionPhase, isStale: Bool = false) -> Color {
    phaseAccentColor(for: phase, isStale: isStale).opacity(isStale ? 0.42 : 0.28)
}

private func neutralSurfaceColor() -> Color {
    Color.white.opacity(0.06)
}

private func neutralSurfaceBorderColor() -> Color {
    Color.white.opacity(0.08)
}

private func shouldPulse(_ phase: SessionPhase) -> Bool {
    switch phase {
    case .working:
        return true
    case .awaitingReply, .needsApproval, .error, .ended:
        return false
    }
}

/// VoiceOver summary combining session name, phase, and key details.
private func accessibilitySummary(
    _ state: PiSessionAttributes.ContentState,
    isStale: Bool = false
) -> String {
    var parts = ["\(state.primarySessionName), \(LiveActivityPresentation.phaseLabel(state.primaryPhase))"]
    if isStale {
        parts.append("Update delayed")
    }
    if state.pendingApprovalCount > 0 {
        parts.append("\(state.pendingApprovalCount) pending approval\(state.pendingApprovalCount == 1 ? "" : "s")")
    }
    if let activity = state.primaryLastActivity, !activity.isEmpty {
        parts.append(activity)
    }
    return parts.joined(separator: ". ")
}

/// Deep link URL for tapping the Live Activity.
///
/// HIG: "Take people directly to related details and actions."
/// - Permission pending → `oppi://permission/<id>` (navigates to approval UI)
/// - Otherwise → `oppi://session/<id>` (opens the primary session)
private func deepLinkURL(for state: PiSessionAttributes.ContentState) -> URL? {
    if let permissionId = state.topPermissionId,
       let encoded = permissionId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) {
        return URL(string: "oppi://permission/\(encoded)")
    }
    if let sessionId = state.primarySessionId,
       let encoded = sessionId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) {
        return URL(string: "oppi://session/\(encoded)")
    }
    return nil
}
