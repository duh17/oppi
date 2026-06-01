import SwiftUI

/// Tracks which app version the user has seen the What's New screen for.
enum WhatsNewManager {
    private static let lastSeenVersionKey = "\(AppIdentifiers.subsystem).whatsNew.lastSeenVersion"

    /// Current marketing version from the bundle.
    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    /// Whether the What's New screen should be shown.
    /// True when the user has never seen it for the current marketing version.
    static var shouldShow: Bool {
        let lastSeen = UserDefaults.standard.string(forKey: lastSeenVersionKey)
        return lastSeen != currentVersion
    }

    /// Mark the current version as seen.
    static func markSeen() {
        UserDefaults.standard.set(currentVersion, forKey: lastSeenVersionKey)
    }
}

// MARK: - Feature Model

private struct WhatsNewFeature: Identifiable {
    let id = UUID()
    let icon: String
    let iconColor: Color
    let title: String
    let description: String
}

// MARK: - View

struct WhatsNewView: View {
    let onContinue: () -> Void

    @State private var appeared = false

    private let features: [WhatsNewFeature] = [
        WhatsNewFeature(
            icon: "terminal",
            iconColor: .themeGreen,
            title: String(localized: "Pi Terminal Mirroring"),
            description: String(localized: "Keep working in a Pi terminal while Oppi mirrors the same session on iPhone or iPad. Watch output, steer, queue follow-ups, and reconnect without taking ownership from the terminal.")
        ),
        WhatsNewFeature(
            icon: "puzzlepiece.extension",
            iconColor: .themePurple,
            title: String(localized: "Extension UI on Mobile"),
            description: String(localized: "Oppi bridges most standard Pi extension UI to device, including input and confirm flows from extensions.")
        ),
        WhatsNewFeature(
            icon: "checkmark.shield",
            iconColor: .themeOrange,
            title: String(localized: "Extension API Compatibility"),
            description: String(localized: "Oppi uses the standard Pi extension UI API for input and confirm flows instead of custom server policy UI.")
        ),
        WhatsNewFeature(
            icon: "ipad.landscape",
            iconColor: .themeCyan,
            title: String(localized: "iPad Workspace Layout"),
            description: String(localized: "The workspace shell adapts to iPad, with a split layout that keeps workspaces, sessions, and chat easier to move between.")
        ),
    ]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 32) {
                    header
                        .padding(.top, 60)

                    featureList
                        .padding(.horizontal, 24)
                }
                .padding(.bottom, 120)
            }
            .scrollBounceBehavior(.basedOnSize)

            continueButton
        }
        .background(Color.themeBg)
        .onAppear {
            withAnimation(.easeOut(duration: 0.5)) {
                appeared = true
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 12) {
            Text("What's New")
                .font(.largeTitle.bold())
                .foregroundStyle(.themeFg)

            Text("in Oppi")
                .font(.title2)
                .foregroundStyle(.themeComment)
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 20)
    }

    // MARK: - Feature List

    private var featureList: some View {
        VStack(spacing: 20) {
            ForEach(Array(features.enumerated()), id: \.element.id) { index, feature in
                featureRow(feature)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 30)
                    .animation(
                        .easeOut(duration: 0.5).delay(Double(index) * 0.08 + 0.15),
                        value: appeared
                    )
            }
        }
    }

    private func featureRow(_ feature: WhatsNewFeature) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: feature.icon)
                .font(.title2)
                .foregroundStyle(feature.iconColor)
                .frame(width: 40, alignment: .center)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(feature.title)
                    .font(.headline)
                    .foregroundStyle(.themeFg)

                Text(feature.description)
                    .font(.subheadline)
                    .foregroundStyle(.themeComment)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Continue Button

    private var continueButton: some View {
        VStack {
            Button {
                WhatsNewManager.markSeen()
                onContinue()
            } label: {
                Text("Continue")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 24)
            .padding(.bottom, 8)
        }
        .padding(.top, 12)
        .background(.ultraThinMaterial)
        .opacity(appeared ? 1 : 0)
        .animation(.easeOut(duration: 0.4).delay(0.6), value: appeared)
    }
}
