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

    /// Build 50 · Changes since Build 49
    private let features: [WhatsNewFeature] = [
        WhatsNewFeature(
            id: "usdz-and-maps",
            icon: "cube.transparent",
            iconColor: .themeBlue,
            title: String(localized: "USDZ, GeoJSON, and TopoJSON"),
            description: String(localized: "USDZ opens in RealityView. GeoJSON and TopoJSON open as maps with a JSON source toggle.")
        ),
        WhatsNewFeature(
            id: "full-screen-viewers",
            icon: "rectangle.portrait.and.arrow.right",
            iconColor: .themeGreen,
            title: String(localized: "Full-screen viewers"),
            description: String(localized: "Rendered maps and diagrams hide Viewing Options until Source. Expanding a tool call to full screen slides in from the right. Staged review comments show on more file views.")
        ),
        WhatsNewFeature(
            id: "official-pi-mark",
            icon: "checkmark.seal",
            iconColor: .themePurple,
            title: String(localized: "Official Pi mark"),
            description: String(localized: "Pi sessions always use the official Pi mark. Grid π and the assistant avatar setting are gone.")
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
