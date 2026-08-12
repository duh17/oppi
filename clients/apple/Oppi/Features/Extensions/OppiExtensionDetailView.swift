import SwiftUI
import UIKit

func oppiApprovalPolicyChoicesAreAvailable(
    oppiIsEnabled: Bool,
    extensionsMutationsAllowed: Bool,
    anySettingPending: Bool = false
) -> Bool {
    oppiIsEnabled
        && extensionsMutationsAllowed
        && !anySettingPending
}

func oppiSettingsControlsAreAvailable(
    extensionsMutationsAllowed: Bool,
    anySettingPending: Bool
) -> Bool {
    extensionsMutationsAllowed && !anySettingPending
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

    private var mobileOutputGuidePending: Bool {
        store.isMutationPending(.oppiMobileOutputGuide, serverId: target.serverId)
    }

    private var anySettingPending: Bool {
        enabledPending || policyPending || mobileOutputGuidePending
    }

    private var settingsControlsAvailable: Bool {
        oppiSettingsControlsAreAvailable(
            extensionsMutationsAllowed: store.mutationsAllowed(
                for: .extensions,
                serverId: target.serverId
            ),
            anySettingPending: anySettingPending
        )
    }

    var body: some View {
        List {
            identitySection
            observedUsageSection

            if let configuration {
                availabilitySection(configuration)
                mobileOutputGuideSection(configuration)
                approvalSection(configuration)
                includedSection

                if let savedMessage {
                    Section {
                        Text(savedMessage)
                            .font(.footnote)
                            .foregroundStyle(.themeGreen)
                            .accessibilityIdentifier("extensions.oppi.savedMessage")
                            .themedListRowBackground()
                    }
                    .themedListRowBackground()
                }
            } else {
                Section {
                    HStack {
                        Spacer()
                        ProgressView("Loading Oppi settings…")
                        Spacer()
                    }
                    .frame(minHeight: 88)
                    .themedListRowBackground()
                }
                .themedListRowBackground()
            }

            if let summary, (summary.state == .error || summary.loadError != nil) {
                Section("Status") {
                    Label("Error", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.themeOrange)
                        .themedListRowBackground()
                    if let error = summary.loadError {
                        Text(error)
                            .font(.footnote)
                            .themedListRowBackground()
                    }
                    Button("Retry") { Task { await refresh() } }
                        .themedListRowBackground()
                }
                .themedListRowBackground()
            }
        }
        .listStyle(.insetGrouped)
        .themedListSurface()
        .foregroundStyle(.themeFg)
        .tint(.themeBlue)
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
            .themedListRowBackground()
        }
        .themedListRowBackground()
    }

    private var observedUsageSection: some View {
        ObservedUsageSection(
            requestKey: ResourceUsageRequestKey(
                serverId: target.serverId,
                subject: ResourceUsageSubject(kind: .extension, id: target.resourceId)
            )
        ) { range, timezone in
            guard let apiClient else {
                throw ResourceUsageLoadError.notConnected
            }
            return try await apiClient.getServerExtensionUsage(
                id: target.resourceId,
                range: range,
                timezone: timezone
            )
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
                    isEnabled: settingsControlsAvailable,
                    accessibilityLabel: "Enable Oppi extension on \(serverName)",
                    accessibilityIdentifier: "extensions.oppi.enabled"
                )

                if enabledPending {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Saving availability")
                }
            }
            .themedListRowBackground()

            Text("Adds the oppi tool to new non-sandbox Pi sessions managed by this server. It does not change sandbox, standalone, or terminal-owned Pi sessions. The Mobile Output Guide is a separate setting and works independently of this tool.")
                .font(.footnote)
                .foregroundStyle(.themeComment)
                .fixedSize(horizontal: false, vertical: true)
                .themedListRowBackground()

            if let error = store.mutationError(for: .oppiEnabled, serverId: target.serverId) {
                Label(
                    "Couldn’t \(availabilityVerb) Oppi on \(serverName). \(error)",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.footnote)
                .foregroundStyle(.themeOrange)
                .accessibilityIdentifier("extensions.oppi.enabled.error")
                .themedListRowBackground()
            }
        }
        .themedListRowBackground()
    }

    @ViewBuilder
    private func mobileOutputGuideSection(_ configuration: OppiExtensionConfiguration) -> some View {
        if configuration.mobileOutputGuideEnabled != nil {
            Section("Mobile Output") {
                HStack(spacing: 10) {
                    Text("Mobile Output Guide")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityHidden(true)

                    OppiAvailabilitySwitch(
                        isOn: Binding(
                            get: { configuration.mobileOutputGuideEnabled == true },
                            set: { enabled in
                                savedMessage = nil
                                Task { await setMobileOutputGuide(enabled) }
                            }
                        ),
                        isEnabled: settingsControlsAvailable,
                        accessibilityLabel: "Enable mobile output guide on \(serverName)",
                        accessibilityIdentifier: "extensions.oppi.mobileOutputGuide"
                    )

                    if mobileOutputGuidePending {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Saving mobile output guide")
                    }
                }
                .listRowBackground(theme.bg.primary)

                Text("Tells agents which links and rich content Oppi can render in new and explicitly reloaded host and sandbox sessions. It does not prescribe a response style. It is independent of Oppi tool availability, does not reload active sessions, and does not affect terminal-owned Mirror sessions.")
                    .font(.footnote)
                    .foregroundStyle(.themeComment)
                    .fixedSize(horizontal: false, vertical: true)
                    .listRowBackground(theme.bg.primary)

                if let error = store.mutationError(for: .oppiMobileOutputGuide, serverId: target.serverId) {
                    Label(
                        "Couldn’t change the mobile output guide on \(serverName). \(error)",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.footnote)
                    .foregroundStyle(.themeOrange)
                    .accessibilityIdentifier("extensions.oppi.mobileOutputGuide.error")
                    .listRowBackground(theme.bg.primary)
                }
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
                        ),
                        anySettingPending: anySettingPending
                    )
                )
                .themedListRowBackground()
            }

            if policyPending {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Saving approval behavior…")
                }
                .font(.footnote)
                .accessibilityElement(children: .combine)
                .themedListRowBackground()
            }

            if let error = store.mutationError(for: .oppiApprovalPolicy, serverId: target.serverId) {
                Label(
                    "Couldn’t change Oppi approval behavior on \(serverName). \(error)",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.footnote)
                .foregroundStyle(.themeOrange)
                .accessibilityIdentifier("extensions.oppi.policy.error")
                .themedListRowBackground()
            }
        }
        .themedListRowBackground()
    }

    private func approvalChoice(
        _ presentation: OppiApprovalPolicyPresentation,
        selected: Bool,
        enabled: Bool
    ) -> some View {
        let isSelectable = enabled
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
                .themedListRowBackground()
            LabeledContent("Structured ask", value: "Not included")
                .themedListRowBackground()
            LabeledContent("Scope", value: serverName)
                .themedListRowBackground()
        }
        .themedListRowBackground()
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

    private func setMobileOutputGuide(_ enabled: Bool) async {
        guard store.mutationsAllowed(for: .extensions, serverId: target.serverId),
              let apiClient else { return }
        await store.setOppiMobileOutputGuide(enabled, serverId: target.serverId, api: apiClient)
        publishSavedMessageIfSettled()
    }

    private func publishSavedMessageIfSettled() {
        guard !enabledPending,
              !policyPending,
              !mobileOutputGuidePending,
              store.mutationError(for: .oppiEnabled, serverId: target.serverId) == nil,
              store.mutationError(for: .oppiApprovalPolicy, serverId: target.serverId) == nil,
              store.mutationError(for: .oppiMobileOutputGuide, serverId: target.serverId) == nil else {
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
    let accessibilityIdentifier: String

    func makeCoordinator() -> Coordinator {
        Coordinator { isOn = $0 }
    }

    func makeUIView(context: Context) -> MinimumHitTargetSwitchContainer {
        let control = MinimumHitTargetSwitchContainer()
        control.nativeSwitch.accessibilityIdentifier = accessibilityIdentifier
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
        control.nativeSwitch.accessibilityIdentifier = accessibilityIdentifier
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
