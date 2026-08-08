import SwiftUI

/// Tracks which app build the user has seen the What's New screen for.
enum WhatsNewManager {
    private static let lastSeenVersionKey = "\(AppIdentifiers.subsystem).whatsNew.lastSeenVersion"

    /// Current marketing version plus build number from the bundle.
    static var currentVersion: String {
        releaseIdentifier(
            marketingVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            buildNumber: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        )
    }

    static func releaseIdentifier(marketingVersion: String?, buildNumber: String?) -> String {
        let version = marketingVersion?.trimmingCharacters(in: .whitespacesAndNewlines)
        let build = buildNumber?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanVersion: String
        if let version, !version.isEmpty {
            cleanVersion = version
        } else {
            cleanVersion = "1.0.0"
        }
        guard let build, !build.isEmpty else { return cleanVersion }
        return "\(cleanVersion) (\(build))"
    }

    /// Whether the What's New screen should be shown.
    /// True when the user has never seen it for the current app build.
    static var shouldShow: Bool {
        let lastSeen = UserDefaults.standard.string(forKey: lastSeenVersionKey)
        return lastSeen != currentVersion
    }

    /// Mark the current app build as seen.
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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    private let features: [WhatsNewFeature] = [
        WhatsNewFeature(
            icon: "person.crop.circle.badge.checkmark",
            iconColor: .themePurple,
            title: String(localized: "Agents, Schedules, and Quick Sessions"),
            description: String(localized: "Edit Agents and schedules directly, assign Skills and Extensions to Agents, and start Quick Sessions with a saved Agent.")
        ),
        WhatsNewFeature(
            icon: "cpu",
            iconColor: .themeOrange,
            title: String(localized: "Model Providers and Quotas"),
            description: String(localized: "Manage providers from the server screen, discover extension models, and see quota bars, reset times, and reset countdowns when the picker opens.")
        ),
        WhatsNewFeature(
            icon: "point.3.connected.trianglepath.dotted",
            iconColor: .themeGreen,
            title: String(localized: "Connection Controls"),
            description: String(localized: "Choose Automatic, HTTPS Only, or Iroh Only for each server. Pairing keeps each client on its authorized transports.")
        ),
        WhatsNewFeature(
            icon: "chart.bar.doc.horizontal",
            iconColor: .themeBlue,
            title: String(localized: "Usage and Linked Resources"),
            description: String(localized: "Review full-history token, cache, and model costs in Context, then open assistant wiki links as workspace or server resources.")
        ),
        WhatsNewFeature(
            icon: "text.document",
            iconColor: .themeCyan,
            title: String(localized: "More Reliable Chat and Review"),
            description: String(localized: "Read long Markdown and tables, keep drafts through extension prompts, and queue /compact until an active turn finishes.")
        ),
        WhatsNewFeature(
            icon: "slider.horizontal.3",
            iconColor: .themeRed,
            title: String(localized: "Safer Server Control"),
            description: String(localized: "Oppi control sessions can manage supported server settings, while explicit model choices fail clearly instead of switching providers.")
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
            if reduceMotion {
                appeared = true
            } else {
                withAnimation(.easeOut(duration: 0.5)) {
                    appeared = true
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 12) {
            Text("What's New")
                .font(.largeTitle.bold())
                .foregroundStyle(.themeFg)

            Text("Builds 43–45")
                .font(.title2)
                .foregroundStyle(.themeComment)
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared || reduceMotion ? 0 : 20)
    }

    // MARK: - Feature List

    private var featureList: some View {
        VStack(spacing: 20) {
            ForEach(Array(features.enumerated()), id: \.element.id) { index, feature in
                featureRow(feature)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared || reduceMotion ? 0 : 30)
                    .animation(
                        reduceMotion ? nil : .easeOut(duration: 0.5).delay(Double(index) * 0.08 + 0.15),
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
        .background(Color.themeSurfaceFill(.opaqueCard).ignoresSafeArea(edges: .bottom))
        .opacity(appeared ? 1 : 0)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.4).delay(0.6), value: appeared)
    }
}
