import Testing
import UIKit
@testable import Oppi

/// The compact guided composer on a detail page: one line at rest, the pills
/// with the field in use, one line again once it is empty and unfocused. A
/// list's full composer keeps its pills.
@Suite("Guided control composer presentation", .serialized)
@MainActor
struct GuidedControlComposerPresentationTests {
    private func makeModel(presentation: GuidedControlComposerPresentation) -> GuidedControlComposerModel {
        let connection = ServerConnection()
        _ = connection.configure(credentials: makeTestCredentials())
        connection.workspaceStore.workspaces = [makeTestWorkspace()]
        return GuidedControlComposerModel(
            configuration: GuidedControlComposerConfiguration(
                domain: .agents,
                intent: .revise,
                presentation: presentation,
                targetId: "agent-1",
                targetName: "Reviewer",
                placeholder: "Describe a change…"
            ),
            connection: { connection },
            navigation: AppNavigation()
        )
    }

    @Test func compactIsOneLineAtRest() {
        let model = makeModel(presentation: .compact)

        #expect(!model.isExpanded)
    }

    @Test func compactOpensWithFocusAndClosesWhenEmptyAndUnfocused() {
        let model = makeModel(presentation: .compact)

        model.inputFocusDidChange(true)
        #expect(model.isExpanded)

        model.inputFocusDidChange(false)
        #expect(!model.isExpanded)
    }

    @Test func compactStaysOpenWhileItHoldsText() {
        let model = makeModel(presentation: .compact)
        model.request = "Make it terser"

        model.inputFocusDidChange(true)
        model.inputFocusDidChange(false)

        #expect(model.isExpanded, "a draft must keep the model and thinking pills in reach")
    }

    @Test func compactTreatsWhitespaceAsEmpty() {
        let model = makeModel(presentation: .compact)
        model.request = " \n "

        #expect(!model.isExpanded)
    }

    @Test func compactStaysOpenWithStagedComments() {
        #expect(GuidedControlComposerPresentation.compact.isExpanded(
            isFocused: false, hasText: false, hasStagedComments: true
        ))
        #expect(!GuidedControlComposerPresentation.compact.isExpanded(
            isFocused: false, hasText: false, hasStagedComments: false
        ))
    }

    @Test func fullPresentationAlwaysShowsItsPills() {
        let model = makeModel(presentation: .full)

        #expect(model.isExpanded)
        model.inputFocusDidChange(true)
        model.inputFocusDidChange(false)
        #expect(model.isExpanded)
    }

    /// What the bar draws: the action row is kept open (so the pills show
    /// without focus) only when the composer is expanded, and the workspace
    /// pill leads it for an Agent revision.
    @Test func theBarShowsPillsOnlyWhenExpanded() throws {
        let root = makeTestAppRoot()
        let compact = GuidedControlComposerController(
            configuration: GuidedControlComposerConfiguration(
                domain: .agents, intent: .revise, presentation: .compact, placeholder: "Describe a change…"
            ),
            root: root
        )
        let full = GuidedControlComposerController(
            configuration: GuidedControlComposerConfiguration(
                domain: .agents, intent: .create, placeholder: "Describe it…"
            ),
            root: root
        )

        #expect(!compact.composerContent.alwaysShowActionRow)
        #expect(full.composerContent.alwaysShowActionRow)

        compact.composerSetText("Make it terser")
        #expect(compact.composerContent.alwaysShowActionRow)
        compact.composerSetText("")
        compact.composerInputFocusDidChange(true)
        #expect(compact.composerContent.alwaysShowActionRow)
        compact.composerInputFocusDidChange(false)
        #expect(!compact.composerContent.alwaysShowActionRow)
    }

    @Test func aPageCanRetargetTheBarWithoutLosingTheDraft() {
        let model = makeModel(presentation: .compact)
        model.request = "Keep this"

        model.updateTarget(id: "agent-1", name: "Renamed", path: nil)

        #expect(model.configuration.targetName == "Renamed")
        #expect(model.request == "Keep this")
        let prompt = model.makeLaunch(cleanRequest: "Keep this").request.prompt ?? ""
        #expect(prompt.contains("Renamed"))
    }

    /// A disabled bar takes no touch, and a hardware-keyboard Return must not
    /// reach Send either: the request would otherwise start a session.
    @Test func aDisabledBarDoesNotSend() async throws {
        let connection = ServerConnection()
        connection.setPreviewAPIClient(APIClient(
            baseURL: try #require(URL(string: "https://preview.invalid")), token: "sk_test"
        ))
        let model = GuidedControlComposerModel(
            configuration: GuidedControlComposerConfiguration(
                domain: .schedules, intent: .revise, presentation: .compact,
                targetId: "s1", targetName: "Nightly", placeholder: "Describe a change…"
            ),
            connection: { connection },
            navigation: AppNavigation()
        )
        model.appear()
        let ready = await waitForMainActorCondition(timeout: .seconds(20)) { model.isInitialized }
        try #require(ready)
        model.request = "Make it hourly"

        model.isDisabled = true
        await model.createControlSession()
        #expect(model.error == nil, "a disabled bar must not reach the server")

        model.isDisabled = false
        await model.createControlSession()
        #expect(model.error != nil, "the same request goes out once the bar is enabled (here it fails offline)")
        model.disappear()
    }
}
