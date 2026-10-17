import ActivityKit
import SwiftUI
import WidgetKit

private let countAnimation = Animation.easeInOut(duration: 0.22)

/// Oppi's counts-only Live Activity on the Lock Screen and in the Dynamic Island: how many
/// agents run and how many wait on you on one server. It shows no session names or text.
struct OppiLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: OppiActivityAttributes.self) { context in
            LockScreenView(state: context.state)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        Glyph(state: context.state, size: 24)
                        Text("Oppi")
                            .font(.caption.bold())
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(spokenSummary(context.state))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    CountBadges(state: context.state)
                        .accessibilityHidden(true)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    SummaryLine(state: context.state)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 6)
                        .padding(.bottom, 6)
                        .accessibilityHidden(true)
                }
            } compactLeading: {
                Glyph(state: context.state, size: 18)
                    .accessibilityLabel(spokenSummary(context.state))
            } compactTrailing: {
                CompactCounts(state: context.state)
                    .accessibilityHidden(true)
            } minimal: {
                Glyph(state: context.state, size: 16)
                    .accessibilityLabel(spokenSummary(context.state))
            }
        }
    }
}

// MARK: - Lock Screen

private struct LockScreenView: View {
    let state: OppiActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 12) {
            Glyph(state: state, size: 34)
            VStack(alignment: .leading, spacing: 4) {
                Text("Oppi")
                    .font(.subheadline.bold())
                SummaryLine(state: state)
            }
            Spacer(minLength: 12)
            CountBadges(state: state)
        }
        .padding(16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenSummary(state))
    }
}

// MARK: - Parts

private struct Glyph: View {
    let state: OppiActivityAttributes.ContentState
    let size: CGFloat

    var body: some View {
        let accent = LiveActivityPresentation.color(state)
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.38, style: .continuous)
                .fill(accent.opacity(0.16))
            RoundedRectangle(cornerRadius: size * 0.38, style: .continuous)
                .strokeBorder(accent.opacity(0.28), lineWidth: 0.9)
            Image(systemName: LiveActivityPresentation.symbol(state))
                .font(.system(size: size * 0.56, weight: .semibold))
                .foregroundStyle(accent)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.pulse, options: .repeating, isActive: state.running > 0 && state.needsYou == 0)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// "3 running · 1 needs you", or "All done" as the card ends.
private struct SummaryLine: View {
    let state: OppiActivityAttributes.ContentState

    var body: some View {
        Text(LiveActivityPresentation.summary(state))
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .contentTransition(.numericText())
            .animation(countAnimation, value: state)
    }
}

private struct CountBadges: View {
    let state: OppiActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 6) {
            if state.running > 0 {
                CountBadge(count: state.running, symbol: "waveform.path.ecg", color: LiveActivityPresentation.runningColor)
            }
            if state.needsYou > 0 {
                CountBadge(count: state.needsYou, symbol: "hand.raised.fill", color: LiveActivityPresentation.needsYouColor)
            }
        }
        .animation(countAnimation, value: state)
    }
}

private struct CountBadge: View {
    let count: Int
    let symbol: String
    let color: Color

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.caption2.weight(.semibold))
            Text("\(count)")
                .font(.caption.monospacedDigit().bold())
                .contentTransition(.numericText(value: Double(count)))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(0.16)))
        .overlay(Capsule().strokeBorder(color.opacity(0.28), lineWidth: 0.8))
    }
}

/// Dynamic Island trailing: the running count, and the waiting count when there is one.
private struct CompactCounts: View {
    let state: OppiActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 4) {
            if state.running > 0 || state.needsYou == 0 {
                Text("\(state.running)")
                    .foregroundStyle(LiveActivityPresentation.runningColor)
            }
            if state.needsYou > 0 {
                Text("\(state.needsYou)")
                    .foregroundStyle(LiveActivityPresentation.needsYouColor)
            }
        }
        .font(.caption.monospacedDigit().bold())
        .contentTransition(.numericText())
        .animation(countAnimation, value: state)
    }
}

private func spokenSummary(_ state: OppiActivityAttributes.ContentState) -> String {
    "Oppi, \(LiveActivityPresentation.summary(state))"
}
