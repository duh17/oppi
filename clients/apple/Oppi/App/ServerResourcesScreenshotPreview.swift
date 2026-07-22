#if DEBUG
import SwiftUI

/// Screenshot-only fixtures for server-scoped resource states that are unsafe or
/// unavailable to seed in the paired E2E server. The E2E journey separately
/// proves the real temporary-server Oppi configuration mutation.
struct ServerResourcesScreenshotPreview: View {
    enum Screen {
        case skills
        case extensions
        case cachedOffline
        case oppi
        case oppiPending
    }

    let screen: Screen

    var body: some View {
        switch screen {
        case .skills:
            ResourceCatalogPreview(kind: .skills, cachedOffline: false)
        case .extensions:
            ResourceCatalogPreview(kind: .extensions, cachedOffline: false)
        case .cachedOffline:
            ResourceCatalogPreview(kind: .extensions, cachedOffline: true)
        case .oppi:
            OppiConfigurationPreview(isPending: false)
        case .oppiPending:
            OppiConfigurationPreview(isPending: true)
        }
    }
}

private struct ResourceCatalogPreview: View {
    enum Kind {
        case skills
        case extensions

        var title: String { self == .skills ? "Skills" : "Extensions" }
        var searchPrompt: String { self == .skills ? "Search skills" : "Search extensions" }
    }

    let kind: Kind
    let cachedOffline: Bool
    @State private var search = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("Preview Server", systemImage: "server.rack")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.themeFg)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Current server: Preview Server")
                        .accessibilityValue(cachedOffline ? "Offline" : "Connected")
                        .accessibilityIdentifier("serverResources.serverScope")
                }

                if cachedOffline {
                    Section {
                        Label(
                            "Showing cached settings for Preview Server. Pull to retry.",
                            systemImage: "exclamationmark.arrow.triangle.2.circlepath"
                        )
                        .font(.subheadline)
                        .foregroundStyle(.themeOrange)
                        .accessibilityIdentifier("serverResources.cachedWarning")
                    }
                }

                switch kind {
                case .skills:
                    skillsSections
                case .extensions:
                    extensionSections
                }
            }
            .listStyle(.insetGrouped)
            .themedListSurface()
            .navigationTitle(kind.title)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: kind.searchPrompt)
        }
        .accessibilityIdentifier("screenshot.ready")
    }

    @ViewBuilder
    private var skillsSections: some View {
        Section("Needs Attention") {
            catalogRow(
                id: "serverResources.skills.error",
                title: "Release checks",
                subtitle: "Invalid frontmatter prevented this skill from loading.",
                provenance: "~/.pi/agent/skills",
                state: "Error",
                isError: true
            )
        }
        Section("Enabled") {
            catalogRow(
                id: "serverResources.skills.release",
                title: "Release", subtitle: "Review release readiness before shipping.",
                provenance: "~/.pi/agent/skills", state: "Enabled", isError: false
            )
        }
        Section("Disabled") {
            catalogRow(
                id: "serverResources.skills.research",
                title: "Deep research", subtitle: "Source-backed, multi-step web research.",
                provenance: "Pi user settings", state: "Disabled", isError: false
            )
        }
    }

    @ViewBuilder
    private var extensionSections: some View {
        Section("Built-in") {
            catalogRow(
                id: "serverResources.extensions.oppi",
                title: "Oppi", subtitle: "Server-owned Oppi command extension.",
                provenance: "Built-in extension", state: "On", isError: false
            )
        }
        Section("Needs Attention") {
            catalogRow(
                id: "serverResources.extensions.error",
                title: "Review helper", subtitle: "Extension could not be loaded.",
                provenance: "Pi user settings", state: "Error", isError: true
            )
        }
        Section("Enabled Pi Extensions") {
            catalogRow(
                id: "serverResources.extensions.workflow",
                title: "Workflow", subtitle: "Coordinates local automation.",
                provenance: "~/.pi/agent/extensions", state: "On", isError: false
            )
        }
    }

    private func catalogRow(
        id: String,
        title: String,
        subtitle: String,
        provenance: String,
        state: String,
        isError: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: kind == .skills ? "sparkles.rectangle.stack" : "puzzlepiece.extension")
                .font(.title3)
                .foregroundStyle(.themeBlue)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.themeFg)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.themeComment)
                Text(provenance)
                    .font(.caption)
                    .foregroundStyle(.themeComment)
                Label(state, systemImage: isError ? "exclamationmark.triangle.fill" : "checkmark.circle")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(isError ? .themeOrange : .themeComment)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.forward")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.themeComment)
                .accessibilityHidden(true)
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(provenance), \(state)")
        .accessibilityIdentifier(id)
    }
}

private struct OppiConfigurationPreview: View {
    let isPending: Bool
    @State private var enabled = true
    @State private var policy: OppiApprovalPolicy = .confirmDestructiveOnly
    @State private var saved = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Oppi")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.themeFg)
                        Text("Built-in extension")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.themeComment)
                        Text("Lets Pi inspect and manage this Oppi server with the allowlisted oppi tool.")
                            .font(.body)
                            .foregroundStyle(.themeComment)
                    }
                    .accessibilityIdentifier("serverResources.oppi.identity")
                }

                Section("Availability") {
                    Toggle("Enable Oppi Extension", isOn: $enabled)
                        .disabled(isPending)
                        .accessibilityLabel("Enable Oppi extension on Preview Server")
                        .accessibilityIdentifier("extensions.oppi.enabled")
                    Text("Adds the oppi tool to new non-sandbox Pi sessions managed by this server. It does not change sandbox, standalone, or terminal-owned Pi sessions.")
                        .font(.footnote)
                        .foregroundStyle(.themeComment)
                }

                Section("Approval Behavior") {
                    approvalChoice(.confirmDestructiveOnly)
                    approvalChoice(.confirmAllChanges)
                    approvalChoice(.readOnly)
                    Text("Selected: \(OppiApprovalPolicyPresentation(policy).title)")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.themeBlue)
                        .accessibilityIdentifier("serverResources.oppi.selectedPolicy")

                    if isPending {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Saving approval behavior…")
                        }
                        .font(.footnote)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("serverResources.oppi.pending")
                    }
                }

                Section {
                    Text(saved ? "Saved on Preview Server. New sessions use this setting. Reload an active session to apply it now." : "New sessions use this setting. Reload an active session to apply it now.")
                        .font(.footnote)
                        .foregroundStyle(saved ? .themeGreen : .themeComment)
                        .accessibilityIdentifier("extensions.oppi.savedMessage")
                }
            }
            .listStyle(.insetGrouped)
            .themedListSurface()
            .navigationTitle("Oppi")
            .navigationBarTitleDisplayMode(.inline)
        }
        .accessibilityIdentifier("screenshot.ready")
    }

    private func approvalChoice(_ candidate: OppiApprovalPolicy) -> some View {
        let presentation = OppiApprovalPolicyPresentation(candidate)
        let selected = policy == candidate
        return Button {
            guard !isPending else { return }
            policy = candidate
            saved = true
        } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(presentation.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.themeFg)
                    Text(presentation.consequence)
                        .font(.footnote)
                        .foregroundStyle(.themeComment)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if selected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.themeBlue)
                        .accessibilityHidden(true)
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled || isPending)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("extensions.oppi.policy.\(candidate.rawValue)")
    }
}
#endif
