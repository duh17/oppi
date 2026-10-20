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
                // Insets keep the top row concentric with the island's 44 pt corners;
                // flush against the region edge the mark's top-left cells were clipped.
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        LiveActivityPiMark(state: context.state, size: 22)
                        Text("Oppi")
                            .font(.caption.bold())
                    }
                    .padding(.leading, 10)
                    .padding(.top, 6)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(spokenSummary(context.state))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    PixelCounts(state: context.state, cellPitch: 3, showsIdleZero: false)
                        .padding(.trailing, 10)
                        .padding(.top, 6)
                        .accessibilityHidden(true)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    SummaryLine(state: context.state)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 6)
                        .accessibilityHidden(true)
                }
            } compactLeading: {
                LiveActivityPiMark(state: context.state, size: 18)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(spokenSummary(context.state))
            } compactTrailing: {
                PixelCounts(state: context.state, cellPitch: 2.4, showsIdleZero: true)
                    .accessibilityHidden(true)
            } minimal: {
                MinimalView(state: context.state)
                    .accessibilityElement(children: .ignore)
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
            LiveActivityPiMark(state: state, size: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text("Oppi")
                    .font(.subheadline.bold())
                SummaryLine(state: state)
            }
            Spacer(minLength: 12)
            PixelCounts(state: state, cellPitch: 3, showsIdleZero: false)
        }
        .padding(16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenSummary(state))
    }
}

// MARK: - Parts

/// Minimal shows live data over a logo when it can (HIG): the waiting count while anything
/// needs you, otherwise the pi mark.
private struct MinimalView: View {
    let state: OppiActivityAttributes.ContentState

    var body: some View {
        if state.needsYou > 0 {
            LiveActivityPixelNumber(value: state.needsYou, color: LiveActivityPresentation.needsYouColor)
        } else {
            LiveActivityPiMark(state: state, size: 16)
        }
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

/// The running count in blue and the waiting count in orange, in the pi mark's pixel cells.
/// Compact trailing keeps a "0" when nothing runs (`showsIdleZero`); the expanded and
/// Lock Screen layouts leave the summary line to say "All done".
private struct PixelCounts: View {
    let state: OppiActivityAttributes.ContentState
    let cellPitch: CGFloat
    let showsIdleZero: Bool

    var body: some View {
        HStack(spacing: cellPitch * 2.5) {
            if state.running > 0 || (showsIdleZero && state.needsYou == 0) {
                LiveActivityPixelNumber(value: state.running, color: LiveActivityPresentation.runningColor, cellPitch: cellPitch)
            }
            if state.needsYou > 0 {
                LiveActivityPixelNumber(value: state.needsYou, color: LiveActivityPresentation.needsYouColor, cellPitch: cellPitch)
            }
        }
        .animation(countAnimation, value: state)
    }
}

private func spokenSummary(_ state: OppiActivityAttributes.ContentState) -> String {
    "Oppi, \(LiveActivityPresentation.summary(state))"
}
