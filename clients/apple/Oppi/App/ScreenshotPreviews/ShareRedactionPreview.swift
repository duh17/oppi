#if DEBUG
import SwiftUI
import UIKit

/// A router screen at the root of a `RouterNavigationController`, the way the
/// router presents a modal with `.inNavigation()`. Previews and harnesses of
/// screens that rely on UIKit bars and the navigator host them here.
/// `content` runs in the screen's own graph: put its fixture environment on
/// it, not on this view.
struct RouterPreviewNavigation<Content: View>: UIViewControllerRepresentable {
    @ViewBuilder let content: () -> Content
    @Environment(\.appRootEnvironment) private var root

    func makeUIViewController(context: Context) -> RouterNavigationController {
        guard let root else {
            preconditionFailure("RouterPreviewNavigation needs appRootEnvironment(_:) above it")
        }
        let navigation = RouterNavigationController(
            rootViewController: HostFactory.screen(root: root, content: content)
        )
        let themeStore = root.themeStore
        navigation.interfaceStyle = { themeStore.userInterfaceStyle }
        return navigation
    }

    func updateUIViewController(_ navigation: RouterNavigationController, context: Context) {}
}

// MARK: - Share Redaction Report Preview

struct ShareRedactionReportPreview: View {
    private let reportLines = [
        "Share URL: https://pi.dev/session/#abc123",
        "Gist: https://gist.github.com/demo-user/abc123",
        "Redaction: 7 replacements",
        "• openai_api_key×1 → [REDACTED_OPENAI_API_KEY] (sk-A…ZZZZ)",
        "• unix_user_path×3 → <path>/[REDACTED_USER] (/Users/…/workspace/oppi)",
        "• email_address×2 → [REDACTED_EMAIL] (a***@example.com)",
        "• github_pat×1 → [REDACTED_GITHUB_TOKEN] (ghp_…9f7a)",
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Share Session")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.themeFg)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Redaction report")
                            .font(.headline)
                            .foregroundStyle(.themeFg)
                            .accessibilityIdentifier("share-redaction-report.title")

                        ForEach(Array(reportLines.enumerated()), id: \.offset) { _, line in
                            reportLine(line)
                        }
                    }
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.themeBgDark)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.themeComment.opacity(0.35), lineWidth: 1)
                    )

                    Text("This preview mirrors the post-share report shown after automatic redaction.")
                        .font(.caption)
                        .foregroundStyle(.themeComment)
                }
                .padding(20)
            }
            .background(Color.themeBg.ignoresSafeArea())
            .navigationTitle("Session Timeline")
            .navigationBarTitleDisplayMode(.inline)
        }
        .accessibilityIdentifier("screenshot.ready")
    }

    private func reportLine(_ line: String) -> some View {
        Text(line)
            .font(.footnote.monospaced())
            .foregroundStyle(.themeFg)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ShareRedactionSettingsPreview: View {
    @State private var policy = ShareSessionRedactionPolicy(
        secrets: true,
        emails: true,
        phones: true,
        userPaths: true,
        ipAddresses: true,
        jwtAndBearer: true,
        namesHeuristic: true,
        skills: true
    )

    private let preflight = ShareSessionPrepareResult(
        canPublish: true,
        blocked: false,
        findings: [
            ShareSessionScanFinding(kind: "openai_api_key", count: 1),
        ],
        artifactBytes: 98_410,
        redaction: ShareSessionRedactionReport(
            policy: ShareSessionRedactionPolicy(
                secrets: true,
                emails: true,
                phones: true,
                userPaths: true,
                ipAddresses: true,
                jwtAndBearer: true,
                namesHeuristic: true,
                skills: true
            ),
            totalReplacements: 11,
            findings: [
                ShareSessionRedactionFinding(
                    kind: "person_name_heuristic",
                    count: 4,
                    replacement: "[REDACTED_PERSON]",
                    samples: ["J*** A***"]
                ),
                ShareSessionRedactionFinding(
                    kind: "email_address",
                    count: 3,
                    replacement: "[REDACTED_EMAIL]",
                    samples: ["a***@example.com"]
                ),
                ShareSessionRedactionFinding(
                    kind: "phone_number",
                    count: 2,
                    replacement: "[REDACTED_PHONE]",
                    samples: ["+1…0199"]
                ),
                ShareSessionRedactionFinding(
                    kind: "unix_user_path",
                    count: 2,
                    replacement: "<path>/[REDACTED_USER]",
                    samples: ["/Users/…/workspace/oppi"]
                ),
            ]
        )
    )

    /// The sheet as chat presents it: a router screen in a navigation controller.
    var body: some View {
        RouterPreviewNavigation {
            ShareSessionRedactionSheet(
                policy: $policy,
                preflight: preflight,
                isAnalyzing: false,
                errorMessage: nil,
                isSharing: false,
                onRefresh: {},
                onShare: {},
                onCancel: {}
            )
        }
        .ignoresSafeArea()
        .accessibilityIdentifier("screenshot.ready")
    }
}
#endif
