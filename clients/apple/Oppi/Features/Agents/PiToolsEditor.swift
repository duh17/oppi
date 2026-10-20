import Foundation
import Observation

/// Pi's default tools, shown on the Pi page (`PiAgentDetailViewController`)
/// and edited on the hosted SwiftUI Tools page it pushes. Both screens read
/// this observable model, so the selection and its saves live here. Every
/// change saves at once, and closing the Tools page saves the selection it
/// leaves with.
@MainActor @Observable
final class PiToolsEditor {
    private(set) var defaultTools: [String]?
    private(set) var builtInTools: [ServerToolSummary] = []
    private(set) var optionalTools: [ServerToolSummary] = []
    private(set) var hasLoadedTools = false
    var error: String?

    var mode: AgentToolSelectionMode = .inherit {
        didSet { if mode != oldValue { selectionChanged(namesChanged: false) } }
    }
    var selectedNames: Set<String> = [] {
        didSet { if selectedNames != oldValue { selectionChanged(namesChanged: true) } }
    }
    var selectedOptionalNames: Set<String> = [] {
        didSet { if selectedOptionalNames != oldValue { selectionChanged(namesChanged: false) } }
    }

    @ObservationIgnored var apiClient: APIClient?
    @ObservationIgnored private var isPickerShown = false
    /// GET and revert write the selection; that is not a user change.
    @ObservationIgnored private var isApplyingLoadedTools = false
    @ObservationIgnored private var toolsSave = AgentManagementPresentation.PiToolsSaveCoordinator()

    var defaultBuiltInSelection: Set<String> {
        Set(builtInTools.filter { $0.defaultEnabled == true }.map(\.name))
    }

    func pickerDidOpen() {
        isPickerShown = true
    }

    func pickerDidClose() {
        guard isPickerShown else { return }
        isPickerShown = false
        save(pickerWasPresented: true, pickerIsPresented: false, selectionChangedAfterLoad: false)
    }

    func applyLoaded(
        _ loaded: [String]?,
        builtInTools: [ServerToolSummary],
        optionalTools: [ServerToolSummary]
    ) {
        self.builtInTools = builtInTools
        self.optionalTools = optionalTools
        applyLoadedDefaultTools(loaded)
    }

    private func applyLoadedDefaultTools(_ loaded: [String]?, isRevertingAfterFailure: Bool = false) {
        guard AgentManagementPresentation.shouldApplyLoadedPiTools(
            hasLoadedTools: hasLoadedTools,
            isSaving: toolsSave.isSaving,
            pickerIsPresented: isPickerShown,
            isRevertingAfterFailure: isRevertingAfterFailure
        ) else {
            hasLoadedTools = true
            return
        }
        isApplyingLoadedTools = true
        defer { isApplyingLoadedTools = false }
        toolsSave = AgentManagementPresentation.PiToolsSaveCoordinator(persisted: loaded)
        defaultTools = loaded
        let selection = AgentManagementPresentation.piToolsSelection(
            defaultTools: loaded,
            builtInTools: builtInTools,
            optionalTools: optionalTools
        )
        mode = selection.mode
        selectedNames = selection.builtInNames
        selectedOptionalNames = selection.optionalNames
        hasLoadedTools = true
    }

    private func selectionChanged(namesChanged: Bool) {
        guard !isApplyingLoadedTools else { return }
        if hasLoadedTools {
            defaultTools = AgentManagementPresentation.piDefaultTools(
                mode: mode,
                selectedNames: selectedNames,
                optionalNames: selectedOptionalNames,
                builtInTools: builtInTools,
                optionalTools: optionalTools
            )
        }
        save(
            pickerWasPresented: isPickerShown,
            pickerIsPresented: isPickerShown,
            selectionChangedAfterLoad: true,
            namesChanged: namesChanged
        )
    }

    private func save(
        pickerWasPresented: Bool,
        pickerIsPresented: Bool,
        selectionChangedAfterLoad: Bool,
        namesChanged: Bool = false
    ) {
        let action = AgentManagementPresentation.piToolsSavePayload(
            leaveHasLoadedTools: hasLoadedTools,
            leaveMode: mode,
            leaveSelectedNames: selectedNames,
            leaveOptionalNames: selectedOptionalNames,
            laterHasLoadedTools: hasLoadedTools,
            laterMode: mode,
            laterSelectedNames: selectedNames,
            builtInTools: builtInTools,
            optionalTools: optionalTools,
            pickerWasPresented: pickerWasPresented,
            pickerIsPresented: pickerIsPresented,
            selectionChangedAfterLoad: selectionChangedAfterLoad,
            isApplyingLoadedTools: isApplyingLoadedTools,
            namesChanged: namesChanged
        )
        guard case .write(let desired) = action else { return }
        // Mark isSaving before the async PUT so a following GET cannot apply stale names.
        guard toolsSave.requestSave(desired: desired) else { return }
        Task {
            await performQueuedSave()
        }
    }

    private func performQueuedSave() async {
        guard let apiClient else {
            let persisted = toolsSave.persisted
            toolsSave.fail()
            applyLoadedDefaultTools(persisted, isRevertingAfterFailure: true)
            return
        }

        while true {
            let next = toolsSave.pendingDesired
            if next == toolsSave.persisted {
                let persisted = toolsSave.persisted
                if !toolsSave.finishAttempt(persisted: persisted) { return }
                continue
            }
            do {
                let saved = try await apiClient.setPiDefaultTools(next)
                defaultTools = saved.defaultTools
                error = nil
                if !toolsSave.finishAttempt(persisted: saved.defaultTools) { return }
            } catch {
                let persisted = toolsSave.persisted
                toolsSave.fail()
                applyLoadedDefaultTools(persisted, isRevertingAfterFailure: true)
                self.error = error.localizedDescription
                return
            }
        }
    }
}
