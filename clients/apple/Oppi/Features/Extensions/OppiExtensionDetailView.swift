import SwiftUI
import UIKit

func oppiApprovalPolicyChoicesAreAvailable(
    oppiIsEnabled: Bool,
    extensionsMutationsAllowed: Bool
) -> Bool {
    oppiIsEnabled && extensionsMutationsAllowed
}

func oppiDetailShouldRefresh(
    configuration: OppiExtensionConfiguration?,
    requiresAuthoritativeRefresh: Bool
) -> Bool {
    configuration == nil || requiresAuthoritativeRefresh
}

struct OppiExtensionDetailView: View {
    @Environment(\.apiClient) private var apiClient
    @Environment(ServerResourceStore.self) private var store
    @Environment(ServerStore.self) private var serverStore
    @Environment(\.theme) private var theme

    let target: ServerResourceDetailNavTarget

    @State private var savedMessage: String?
    @State private var availabilityVerb = "update"

    private var serverName: String {
        serverStore.server(for: target.serverId)?.name ?? "this server"
    }

    private var summary: ServerExtensionSummary? {
        store.extensions(forServer: target.serverId).first {
            $0.id == target.resourceId && $0.isBuiltInOppi
        }
    }

    private var configuration: OppiExtensionConfiguration? {
        store.oppiConfiguration(forServer: target.serverId)
    }

    private var enabledPending: Bool {
        store.isMutationPending(.oppiEnabled, serverId: target.serverId)
    }

    private var policyPending: Bool {
        store.isMutationPending(.oppiApprovalPolicy, serverId: target.serverId)
    }

    var body: some View {
        List {
            identitySection

            if let configuration {
                availabilitySection(configuration)
                approvalSection(configuration)
                includedSection

                Section {
                    Text(savedMessage ?? "New sessions use this setting. Reload an active session to apply it now.")
                        .font(.footnote)
                        .foregroundStyle(savedMessage == nil ? .themeComment : .themeGreen)
                        .accessibilityIdentifier("extensions.oppi.savedMessage")
                        .listRowBackground(theme.bg.primary)
                }
            } else {
                Section {
                    HStack {
                        Spacer()
                        ProgressView("Loading Oppi settings…")
                        Spacer()
                    }
                    .frame(minHeight: 88)
                    .listRowBackground(theme.bg.primary)
                }
            }

            if let summary, (summary.state == .error || summary.loadError != nil) {
                Section("Status") {
                    Label("Error", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.themeOrange)
                        .listRowBackground(theme.bg.primary)
                    if let error = summary.loadError {
                        Text(error)
                            .font(.footnote)
                            .listRowBackground(theme.bg.primary)
                    }
                    Button("Retry") { Task { await refresh() } }
                        .listRowBackground(theme.bg.primary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .themedListSurface()
        .navigationTitle("Oppi")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: target) {
            if oppiDetailShouldRefresh(
                configuration: configuration,
                requiresAuthoritativeRefresh: store.requiresAuthoritativeOppiRefresh(
                    forServer: target.serverId
                )
            ) {
                await refresh()
            }
        }
    }

    private var identitySection: some View {
        Section {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "puzzlepiece.extension.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.themeBlue)
                    .frame(width: 44, height: 44)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Oppi")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.themeFg)
                    Text("Built-in extension")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.themeComment)
                    Text("Lets Pi inspect and manage this Oppi server with the allowlisted oppi tool.")
                        .font(.body)
                        .foregroundStyle(.themeComment)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 6)
            .accessibilityElement(children: .combine)
            .listRowBackground(theme.bg.primary)
        }
    }

    private func availabilitySection(_ configuration: OppiExtensionConfiguration) -> some View {
        Section("Availability") {
            HStack(spacing: 10) {
                Text("Enable Oppi Extension")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityHidden(true)

                OppiAvailabilitySwitch(
                    isOn: Binding(
                        get: { configuration.enabled },
                        set: { enabled in
                            savedMessage = nil
                            availabilityVerb = enabled ? "enable" : "disable"
                            Task { await setEnabled(enabled) }
                        }
                    ),
                    isEnabled: !enabledPending
                        && store.mutationsAllowed(for: .extensions, serverId: target.serverId),
                    accessibilityLabel: "Enable Oppi extension on \(serverName)"
                )

                if enabledPending {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Saving availability")
                }
            }
            .listRowBackground(theme.bg.primary)

            Text("Adds the oppi tool to new non-sandbox Pi sessions managed by this server. It does not change sandbox, standalone, or terminal-owned Pi sessions.")
                .font(.footnote)
                .foregroundStyle(.themeComment)
                .fixedSize(horizontal: false, vertical: true)
                .listRowBackground(theme.bg.primary)

            if let error = store.mutationError(for: .oppiEnabled, serverId: target.serverId) {
                Label(
                    "Couldn’t \(availabilityVerb) Oppi on \(serverName). \(error)",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.footnote)
                .foregroundStyle(.themeOrange)
                .accessibilityIdentifier("extensions.oppi.enabled.error")
                .listRowBackground(theme.bg.primary)
            }
        }
    }

    private func approvalSection(_ configuration: OppiExtensionConfiguration) -> some View {
        Section("Approval Behavior") {
            ForEach(
                [
                    OppiApprovalPolicy.confirmDestructiveOnly,
                    .confirmAllChanges,
                    .readOnly,
                ],
                id: \.rawValue
            ) { policy in
                approvalChoice(
                    OppiApprovalPolicyPresentation(policy),
                    selected: configuration.approvalPolicy == policy,
                    enabled: oppiApprovalPolicyChoicesAreAvailable(
                        oppiIsEnabled: configuration.enabled,
                        extensionsMutationsAllowed: store.mutationsAllowed(
                            for: .extensions,
                            serverId: target.serverId
                        )
                    )
                )
                .listRowBackground(theme.bg.primary)
            }

            if policyPending {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Saving approval behavior…")
                }
                .font(.footnote)
                .accessibilityElement(children: .combine)
                .listRowBackground(theme.bg.primary)
            }

            if let error = store.mutationError(for: .oppiApprovalPolicy, serverId: target.serverId) {
                Label(
                    "Couldn’t change Oppi approval behavior on \(serverName). \(error)",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.footnote)
                .foregroundStyle(.themeOrange)
                .accessibilityIdentifier("extensions.oppi.policy.error")
                .listRowBackground(theme.bg.primary)
            }
        }
    }

    private func approvalChoice(
        _ presentation: OppiApprovalPolicyPresentation,
        selected: Bool,
        enabled: Bool
    ) -> some View {
        let isSelectable = enabled && !policyPending
        return Button {
            guard !selected, isSelectable else { return }
            savedMessage = nil
            Task { await setApprovalPolicy(presentation.policy) }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(presentation.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.themeFg)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(presentation.consequence)
                        .font(.footnote)
                        .foregroundStyle(.themeComment)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if selected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.themeBlue)
                        .frame(width: 24, height: 24)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isSelectable)
        .opacity(isSelectable ? 1 : 0.5)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("extensions.oppi.policy.\(presentation.policy.rawValue)")
    }

    private var includedSection: some View {
        Section("Included") {
            LabeledContent("Tool", value: "oppi — Included")
                .listRowBackground(theme.bg.primary)
            LabeledContent("Structured ask", value: "Not included")
                .listRowBackground(theme.bg.primary)
            LabeledContent("Scope", value: serverName)
                .listRowBackground(theme.bg.primary)
        }
    }

    private func setEnabled(_ enabled: Bool) async {
        guard let apiClient else { return }
        await store.setOppiEnabled(enabled, serverId: target.serverId, api: apiClient)
        publishSavedMessageIfSettled()
    }

    private func setApprovalPolicy(_ policy: OppiApprovalPolicy) async {
        guard store.mutationsAllowed(for: .extensions, serverId: target.serverId),
              let apiClient else { return }
        await store.setOppiApprovalPolicy(policy, serverId: target.serverId, api: apiClient)
        publishSavedMessageIfSettled()
    }

    private func publishSavedMessageIfSettled() {
        guard !enabledPending,
              !policyPending,
              store.mutationError(for: .oppiEnabled, serverId: target.serverId) == nil,
              store.mutationError(for: .oppiApprovalPolicy, serverId: target.serverId) == nil else {
            return
        }
        savedMessage = OppiApprovalPolicyPresentation.savedMessage(serverName: serverName)
    }

    private func refresh() async {
        guard let apiClient else { return }
        await store.load(
            serverId: target.serverId,
            fetchSkills: { try await apiClient.listServerSkills() },
            fetchExtensions: { try await apiClient.listServerExtensions() }
        )
    }
}

private struct OppiAvailabilitySwitch: UIViewRepresentable {
    @Binding var isOn: Bool
    let isEnabled: Bool
    let accessibilityLabel: String

    func makeCoordinator() -> Coordinator {
        Coordinator { isOn = $0 }
    }

    func makeUIView(context: Context) -> MinimumHitTargetSwitchContainer {
        let control = MinimumHitTargetSwitchContainer()
        control.nativeSwitch.addTarget(
            context.coordinator,
            action: #selector(Coordinator.valueChanged(_:)),
            for: .valueChanged
        )
        return control
    }

    func updateUIView(_ control: MinimumHitTargetSwitchContainer, context: Context) {
        context.coordinator.onChange = { isOn = $0 }
        control.nativeSwitch.setOn(isOn, animated: false)
        control.isEnabled = isEnabled
        control.nativeSwitch.isEnabled = isEnabled
        control.nativeSwitch.accessibilityLabel = accessibilityLabel
    }

    @MainActor
    final class Coordinator: NSObject {
        var onChange: (Bool) -> Void

        init(onChange: @escaping (Bool) -> Void) {
            self.onChange = onChange
        }

        @objc func valueChanged(_ sender: UISwitch) {
            onChange(sender.isOn)
        }
    }
}

/// Keeps one native switch accessibility element while its containing control
/// handles taps throughout a real 44pt vertical target.
private final class MinimumHitTargetSwitchContainer: UIControl {
    let nativeSwitch = UISwitch()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = false
        nativeSwitch.isAccessibilityElement = true
        nativeSwitch.accessibilityIdentifier = "extensions.oppi.enabled"
        addSubview(nativeSwitch)
        addTarget(self, action: #selector(toggleFromExpandedTarget), for: .touchUpInside)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: nativeSwitch.intrinsicContentSize.width, height: 44)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        nativeSwitch.sizeToFit()
        nativeSwitch.center = CGPoint(x: bounds.midX, y: bounds.midY)
        nativeSwitch.accessibilityFrame = convert(bounds, to: nil)
    }

    @objc private func toggleFromExpandedTarget() {
        guard isEnabled else { return }
        nativeSwitch.setOn(!nativeSwitch.isOn, animated: true)
        nativeSwitch.sendActions(for: .valueChanged)
    }
}
