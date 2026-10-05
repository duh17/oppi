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

    /// Whether the What's New changelog should be shown.
    /// First install is not a changelog. Upgrades show it once per release.
    static var shouldShow: Bool {
        shouldShowChangelog(
            lastSeenVersion: UserDefaults.standard.string(forKey: lastSeenVersionKey),
            currentVersion: currentVersion
        )
    }

    static func shouldShowChangelog(lastSeenVersion: String?, currentVersion: String) -> Bool {
        guard let lastSeenVersion, !lastSeenVersion.isEmpty else { return false }
        return lastSeenVersion != currentVersion
    }

    /// Persist this release on first launch so a later upgrade can show What's New.
    static func recordFirstLaunchIfNeeded() {
        if UserDefaults.standard.string(forKey: lastSeenVersionKey) == nil {
            markSeen()
        }
    }

    /// Mark the current app build as seen.
    static func markSeen() {
        UserDefaults.standard.set(currentVersion, forKey: lastSeenVersionKey)
    }

    static func caption(marketingVersion: String?) -> String {
        let version = marketingVersion?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if version.isEmpty {
            return String(localized: "What’s new in this version")
        }
        return String(localized: "Version \(version)")
    }
}

// MARK: - Feature Model

private struct WhatsNewFeature: Identifiable {
    let id: String
    let icon: String
    let iconColor: ThemeShapeStyle
    let title: String
    let description: String
}

// MARK: - View

struct WhatsNewView: View {
    let onContinue: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    /// Build 53 · Changes since Build 52
    private let features: [WhatsNewFeature] = [
        WhatsNewFeature(
            id: "message-queue",
            icon: "tray.full",
            iconColor: .themeGreen,
            title: String(localized: "Simpler message queue"),
            description: String(localized: "Remove a queued message, or move the queue back into the composer with Edit in composer. Stop does the same first. Editing in place, reordering, and moving between steer and follow-up are gone. Needs server 0.51.0.")
        ),
        WhatsNewFeature(
            id: "connections",
            icon: "wifi",
            iconColor: .themeBlue,
            title: String(localized: "Steadier connections"),
            description: String(localized: "On Wi-Fi, Oppi tries your local network first. Settings → Network → Tailscale joins your tailnet without the Tailscale app, and setup can pair through it.")
        ),
        WhatsNewFeature(
            id: "mcp-servers",
            icon: "puzzlepiece.extension",
            iconColor: .themePurple,
            title: String(localized: "MCP servers and Pi 1.0"),
            description: String(localized: "Manage MCP servers and project trust from iPhone. The server now bundles Pi 1.0.2.")
        ),
        WhatsNewFeature(
            id: "restart-resume",
            icon: "arrow.clockwise",
            iconColor: .themeOrange,
            title: String(localized: "Sessions resume after a restart"),
            description: String(localized: "Sessions running when the server restarts continue on the next start. A session caught mid-turn is asked to carry on.")
        ),
        WhatsNewFeature(
            id: "experiments",
            icon: "testtube.2",
            iconColor: .themeComment,
            title: String(localized: "Opt-in experiments"),
            description: String(localized: "Session Threads and SSH Terminal are off by default. Turn them on under Settings → Experiments.")
        ),
    ]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    header
                        .padding(.top, 28)
                        .padding(.horizontal, 24)

                    featureList
                        .padding(.top, 28)
                        .padding(.horizontal, 24)
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 24)
            }
            .scrollBounceBehavior(.basedOnSize)

            continueButton
        }
        .background {
            Rectangle()
                .fill(.themeBg)
                .ignoresSafeArea()
        }
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
        VStack(spacing: 6) {
            Text(String(localized: "What’s New in Oppi"))
                .font(.largeTitle.bold())
                .foregroundStyle(.themeFg)
                .accessibilityIdentifier("whatsNew.title")

            Text(
                WhatsNewManager.caption(
                    marketingVersion: Bundle.main.object(
                        forInfoDictionaryKey: "CFBundleShortVersionString"
                    ) as? String
                )
            )
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.themeComment)
                .accessibilityIdentifier("whatsNew.caption")
        }
        .multilineTextAlignment(.center)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared || reduceMotion ? 0 : 20)
    }

    // MARK: - Feature List

    private var featureList: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(Array(features.enumerated()), id: \.element.id) { index, feature in
                featureRow(feature)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared || reduceMotion ? 0 : 30)
                    .animation(
                        reduceMotion ? nil : .easeOut(duration: 0.5).delay(Double(index) * 0.06 + 0.1),
                        value: appeared
                    )
            }
        }
    }

    private func featureRow(_ feature: WhatsNewFeature) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: feature.icon)
                .font(.title3.weight(.semibold))
                .foregroundStyle(feature.iconColor)
                .frame(width: 28, height: 28)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                Text(feature.title)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.themeFg)
                    .accessibilityIdentifier("whatsNew.feature.\(feature.id).title")

                Text(feature.description)
                    .font(.subheadline)
                    .foregroundStyle(.themeComment)
                    .lineSpacing(1)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("whatsNew.feature.\(feature.id).description")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("whatsNew.feature.\(feature.id)")
    }

    // MARK: - Continue Button

    private var continueButton: some View {
        VStack(spacing: 0) {
            Button {
                WhatsNewManager.markSeen()
                onContinue()
            } label: {
                Text("Done")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .accessibilityIdentifier("whatsNew.done")
        }
        .background {
            Rectangle()
                .fill(.themeBgDark)
                .ignoresSafeArea(edges: .bottom)
        }
        .opacity(appeared ? 1 : 0)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.4).delay(0.6), value: appeared)
    }
}
