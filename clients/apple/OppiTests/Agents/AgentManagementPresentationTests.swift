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

    @Test func piToolsBackSaveUsesExactSelectionCapturedAtLeaveEvenIfLaterStateResetsToInherit() {
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
            builtInTools: builtIn
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
                builtInTools: builtIn
            ) == .write(nil)
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
