import Foundation
import Testing
@testable import Oppi

@Suite("Agent management presentation")
struct AgentManagementPresentationTests {
    @Test func piIsAlwaysFirstAndIsNotBackedByASavedAgentID() {
        let saved = AgentDefinitionSummary(
            id: "reviewer",
            name: "Reviewer",
            icon: .defaultValue,
            status: .active,
            version: 1,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )

        let rows = AgentManagementPresentation.rows(savedAgents: [saved])

        #expect(rows.count == 2)
        #expect(rows[0] == .pi)
        #expect(rows[0].agentId == nil)
        #expect(rows[0].name == "Pi")
        #expect(rows[1].agentId == "reviewer")
    }

    @Test func officialPiAvatarIsStaticAndIndependentOfSavedAgentIcons() {
        #expect(AgentManagementPresentation.piAvatar == .officialPi)
        #expect(AgentManagementPresentation.globalSystemPromptPath == "~/.pi/agent/SYSTEM.md")
        #expect(AgentManagementPresentation.piIdentityAccessibilityLabel == "Pi, Official Pi avatar")
        #expect(!AgentManagementPresentation.piIdentityAccessibilityLabel.contains("Ordinary upstream Pi"))
    }

    @Test func piPromptFileIsReviewableAndMissingFileUsesTheDefaultLabel() {
        #expect(AgentManagementPresentation.piPromptIsReviewable(.file))
        #expect(!AgentManagementPresentation.piPromptIsReviewable(.default))
        #expect(
            AgentManagementPresentation.piDefaultPromptInUseLabel
                == "Pi default in use until SYSTEM.md exists"
        )
        #expect(
            AgentManagementPresentation.piSystemPromptAccessibilityLabel(source: .default)
                == AgentManagementPresentation.piDefaultPromptInUseLabel
        )
        #expect(
            AgentManagementPresentation.piSystemPromptAccessibilityValue(source: .default)
                == AgentManagementPresentation.piDefaultPromptInUseLabel
        )
        #expect(
            AgentManagementPresentation.piSystemPromptAccessibilityLabel(source: .file)
                == "Read and comment on SYSTEM.md"
        )
        #expect(AgentManagementPresentation.piSystemPromptAccessibilityValue(source: .file) == nil)
    }

    @Test func piToolsSaveCoalescesANewerSelectionWhileAWriteIsInFlight() {
        var save = AgentManagementPresentation.PiToolsSaveCoordinator(persisted: nil)
        let started = save.requestSave()
        let queuedWhileInFlight = save.requestSave()
        let continueAfterFirstWrite = save.finishAttempt(persisted: ["read"])
        let continueAfterLatestWrite = save.finishAttempt(persisted: ["read", "grep"])
        #expect(started)
        #expect(!queuedWhileInFlight)
        #expect(continueAfterFirstWrite)
        #expect(save.persisted == ["read", "grep"])
        #expect(!continueAfterLatestWrite)
        #expect(!save.isSaving)
        let restartAfterSettle = save.requestSave()
        #expect(restartAfterSettle)
    }

    @Test func piToolsSaveRetriesAfterAnUnchangedSkipWhenANewerSelectionQueued() {
        var save = AgentManagementPresentation.PiToolsSaveCoordinator(persisted: ["read"])
        let started = save.requestSave()
        let queuedWhileInFlight = save.requestSave()
        let continueAfterUnchanged = save.finishAttempt(persisted: ["read"])
        save.fail()
        #expect(started)
        #expect(!queuedWhileInFlight)
        #expect(continueAfterUnchanged)
        #expect(!save.isSaving)
        #expect(save.persisted == ["read"])
    }

    @Test func piToolsDismissProducesWriteEvenIfLaterStateResetsToInherit() {
        let builtIn = [
            ServerToolSummary(name: "read", defaultEnabled: true),
            ServerToolSummary(name: "bash", defaultEnabled: true),
            ServerToolSummary(name: "grep", defaultEnabled: false),
        ]

        let payload = AgentManagementPresentation.piToolsSavePayload(
            leaveHasLoadedTools: true,
            leaveMode: .exact,
            leaveSelectedNames: ["grep"],
            laterHasLoadedTools: false,
            laterMode: .inherit,
            laterSelectedNames: [],
            builtInTools: builtIn,
            pickerWasPresented: true,
            pickerIsPresented: false,
            selectionChangedAfterLoad: false
        )

        #expect(payload == .write(["grep"]))
        #expect(
            AgentManagementPresentation.piToolsSavePayload(
                leaveHasLoadedTools: true,
                leaveMode: .inherit,
                leaveSelectedNames: ["read", "bash"],
                laterHasLoadedTools: true,
                laterMode: .exact,
                laterSelectedNames: ["grep"],
                builtInTools: builtIn,
                pickerWasPresented: true,
                pickerIsPresented: false,
                selectionChangedAfterLoad: false
            ) == .write(nil)
        )
    }

    @Test func piToolsSelectionChangeAfterLoadProducesWriteEvenIfLaterStateResetsToInherit() {
        let builtIn = [
            ServerToolSummary(name: "read", defaultEnabled: true),
            ServerToolSummary(name: "bash", defaultEnabled: true),
            ServerToolSummary(name: "grep", defaultEnabled: false),
        ]

        let payload = AgentManagementPresentation.piToolsSavePayload(
            leaveHasLoadedTools: true,
            leaveMode: .exact,
            leaveSelectedNames: ["grep"],
            laterHasLoadedTools: true,
            laterMode: .inherit,
            laterSelectedNames: [],
            builtInTools: builtIn,
            pickerWasPresented: true,
            pickerIsPresented: true,
            selectionChangedAfterLoad: true
        )

        #expect(payload == .write(["grep"]))
    }

    @Test func piToolsDoesNotWriteWithoutDismissOrSelectionChange() {
        let builtIn = [
            ServerToolSummary(name: "read", defaultEnabled: true),
            ServerToolSummary(name: "grep", defaultEnabled: false),
        ]

        #expect(
            AgentManagementPresentation.piToolsSavePayload(
                leaveHasLoadedTools: true,
                leaveMode: .exact,
                leaveSelectedNames: ["grep"],
                laterHasLoadedTools: true,
                laterMode: .exact,
                laterSelectedNames: ["grep"],
                builtInTools: builtIn,
                pickerWasPresented: false,
                pickerIsPresented: false,
                selectionChangedAfterLoad: false
            ) == .skip
        )
    }

    @Test func loadedPiToolsApplyDoesNotProduceAUserSelectionWrite() {
        let builtIn = [
            ServerToolSummary(name: "read", defaultEnabled: true),
            ServerToolSummary(name: "grep", defaultEnabled: false),
        ]

        #expect(
            AgentManagementPresentation.piToolsSavePayload(
                leaveHasLoadedTools: true,
                leaveMode: .exact,
                leaveSelectedNames: ["read"],
                laterHasLoadedTools: true,
                laterMode: .exact,
                laterSelectedNames: ["read"],
                builtInTools: builtIn,
                pickerWasPresented: false,
                pickerIsPresented: false,
                selectionChangedAfterLoad: true,
                isApplyingLoadedTools: true
            ) == .skip
        )
    }

    @Test func piToolsNamesChangeWhileInheritDoesNotWrite() {
        let builtIn = [
            ServerToolSummary(name: "read", defaultEnabled: true),
            ServerToolSummary(name: "bash", defaultEnabled: true),
        ]

        #expect(
            AgentManagementPresentation.piToolsSavePayload(
                leaveHasLoadedTools: true,
                leaveMode: .inherit,
                leaveSelectedNames: ["read", "bash"],
                laterHasLoadedTools: true,
                laterMode: .inherit,
                laterSelectedNames: ["read"],
                builtInTools: builtIn,
                pickerWasPresented: true,
                pickerIsPresented: true,
                selectionChangedAfterLoad: true,
                namesChanged: true
            ) == .skip
        )
    }

    @Test func piToolsModeChangeToInheritWritesNull() {
        let builtIn = [
            ServerToolSummary(name: "read", defaultEnabled: true),
            ServerToolSummary(name: "bash", defaultEnabled: true),
        ]

        #expect(
            AgentManagementPresentation.piToolsSavePayload(
                leaveHasLoadedTools: true,
                leaveMode: .inherit,
                leaveSelectedNames: ["read", "bash"],
                laterHasLoadedTools: true,
                laterMode: .inherit,
                laterSelectedNames: ["read", "bash"],
                builtInTools: builtIn,
                pickerWasPresented: true,
                pickerIsPresented: true,
                selectionChangedAfterLoad: true
            ) == .write(nil)
        )
    }

    @Test func revertAfterFailureAppliesLoadedPiToolsWhilePickerPresented() {
        #expect(
            AgentManagementPresentation.shouldApplyLoadedPiTools(
                hasLoadedTools: true,
                isSaving: false,
                pickerIsPresented: true,
                isRevertingAfterFailure: true
            )
        )
    }

    @Test func loadedPiToolsDoNotReplaceSelectionWhileSavingOrPickerPresented() {
        #expect(
            AgentManagementPresentation.shouldApplyLoadedPiTools(
                hasLoadedTools: false,
                isSaving: true,
                pickerIsPresented: true
            )
        )
        #expect(
            AgentManagementPresentation.shouldApplyLoadedPiTools(
                hasLoadedTools: true,
                isSaving: false,
                pickerIsPresented: false
            )
        )
        #expect(
            !AgentManagementPresentation.shouldApplyLoadedPiTools(
                hasLoadedTools: true,
                isSaving: true,
                pickerIsPresented: false
            )
        )
        #expect(
            !AgentManagementPresentation.shouldApplyLoadedPiTools(
                hasLoadedTools: true,
                isSaving: false,
                pickerIsPresented: true
            )
        )
    }

    @Test func piToolsSummaryTreatsOmittedDefaultToolsAsPiStandard() {
        #expect(AgentManagementPresentation.piToolsSummary(defaultTools: nil) == "Pi standard")
        #expect(AgentManagementPresentation.piToolsSummary(defaultTools: []) == "None")
        #expect(AgentManagementPresentation.piToolsSummary(defaultTools: ["read", "grep"]) == "read, grep")
        #expect(
            AgentManagementPresentation.piExactToolNames(
                selectedNames: ["grep", "read", "unknown"],
                builtInTools: [
                    ServerToolSummary(name: "read", defaultEnabled: true),
                    ServerToolSummary(name: "bash", defaultEnabled: true),
                    ServerToolSummary(name: "grep", defaultEnabled: false),
                ]
            ) == ["read", "grep"]
        )
    }
}
