import Foundation
import Testing
@testable import Oppi

@Suite("Navigation breadcrumbs")
@MainActor
struct NavigationBreadcrumbTests {
    @Test func unchangedRouteDoesNotLog() {
        let snapshot = NavigationRouteSnapshot(
            screen: "workspace_inbox_all",
            stackDepth: 0,
            presentation: "stack",
            sessionId: nil,
            workspaceId: nil
        )

        #expect(NavigationRouteTelemetry.log(previous: snapshot, current: snapshot) == nil)
    }

    @Test func routeChangeRecordsPreviousScreenAndIds() {
        let previous = NavigationRouteSnapshot(
            screen: "workspace_inbox_all",
            stackDepth: 0,
            presentation: "stack",
            sessionId: nil,
            workspaceId: nil
        )
        let current = NavigationRouteSnapshot(
            screen: "workspace_session",
            stackDepth: 2,
            presentation: "stack",
            sessionId: "session-1",
            workspaceId: "workspace-1"
        )

        let log = NavigationRouteTelemetry.log(previous: previous, current: current)

        #expect(log?.message == "Route changed")
        #expect(log?.metadata["screen"] == "workspace_session")
        #expect(log?.metadata["previousScreen"] == "workspace_inbox_all")
        #expect(log?.metadata["stackDepth"] == "2")
        #expect(log?.metadata["presentation"] == "stack")
        #expect(log?.metadata["sessionId"] == "session-1")
        #expect(log?.metadata["workspaceId"] == "workspace-1")
    }

    @Test func firstRouteUsesNoneAsPreviousScreen() {
        let log = NavigationRouteTelemetry.log(
            previous: nil,
            current: NavigationRouteSnapshot(
                screen: "launch_resolving",
                stackDepth: 0,
                presentation: "stack",
                sessionId: nil,
                workspaceId: nil
            )
        )

        #expect(log?.metadata["previousScreen"] == "none")
        #expect(log?.metadata["sessionId"] == nil)
    }

    @Test func coalescedBurstEmitsOnlyTheFinalChange() {
        var logs: [NavigationRouteLog] = []
        let coalescer = NavigationRouteTelemetryCoalescer(
            schedule: { _ in },
            emit: { logs.append($0) }
        )
        coalescer.note(NavigationRouteSnapshot(
            screen: "workspace_inbox_all",
            stackDepth: 0,
            presentation: "stack",
            sessionId: nil,
            workspaceId: "workspace-1"
        ))
        coalescer.note(NavigationRouteSnapshot(
            screen: "workspace_session",
            stackDepth: 2,
            presentation: "stack",
            sessionId: "session-1",
            workspaceId: "workspace-1"
        ))

        coalescer.flush()
        coalescer.note(NavigationRouteSnapshot(
            screen: "workspace_session",
            stackDepth: 2,
            presentation: "stack",
            sessionId: "session-1",
            workspaceId: "workspace-1"
        ))
        coalescer.flush()

        #expect(logs.count == 1)
        #expect(logs[0].metadata["screen"] == "workspace_session")
        #expect(logs[0].metadata["previousScreen"] == "none")
        #expect(logs[0].metadata["sessionId"] == "session-1")
    }

    @Test func sessionRouteIsPreservedOnlyWhenTheSameSessionSurvives() {
        #expect(NavigationPresentationTelemetry.sessionRoutePreserved(
            fromSessionId: "session-1",
            toSessionId: "session-1"
        ))
        #expect(!NavigationPresentationTelemetry.sessionRoutePreserved(
            fromSessionId: "session-1",
            toSessionId: nil
        ))
        #expect(!NavigationPresentationTelemetry.sessionRoutePreserved(
            fromSessionId: nil,
            toSessionId: "session-1"
        ))

        let metadata = NavigationPresentationTelemetry.metadata(
            from: "stack",
            to: "split",
            measurement: WorkspaceNavigationMeasurement(
                horizontalSizeClass: "regular",
                verticalSizeClass: "regular",
                windowWidth: 1180,
                windowHeight: 820
            ),
            fromSessionId: "session-1",
            toSessionId: "session-1"
        )
        #expect(metadata["from"] == "stack")
        #expect(metadata["to"] == "split")
        #expect(metadata["horizontalSizeClass"] == "regular")
        #expect(metadata["verticalSizeClass"] == "regular")
        #expect(metadata["windowWidth"] == "1180")
        #expect(metadata["windowHeight"] == "820")
        #expect(metadata["sessionRoutePreserved"] == "true")
        #expect(metadata["sessionId"] == "session-1")
    }

    @Test func chatRemountRecordsTimeSinceThePreviousMount() {
        var mounts: [String: TimeInterval] = [:]
        let first = ChatMountTelemetry.appearMetadata(
            sessionId: "session-1",
            shellSwapRemount: false,
            presentation: "stack",
            now: 10,
            lastMountUptime: &mounts
        )
        let remount = ChatMountTelemetry.appearMetadata(
            sessionId: "session-1",
            shellSwapRemount: true,
            presentation: "split",
            now: 12.25,
            lastMountUptime: &mounts
        )

        #expect(first["sincePreviousMountMs"] == nil)
        #expect(first["shellSwapRemount"] == "false")
        #expect(remount["shellSwapRemount"] == "true")
        #expect(remount["sincePreviousMountMs"] == "2250")
        #expect(remount["sessionId"] == "session-1")
    }

    @Test func buildIdentityOmitsBlankUnexpandedAndNonShaStamps() {
        #expect(AppBuildIdentity.gitCommit(infoValue: nil) == nil)
        #expect(AppBuildIdentity.gitCommit(infoValue: "  ") == nil)
        #expect(AppBuildIdentity.gitCommit(infoValue: "$(OPPI_GIT_COMMIT)") == nil)
        #expect(AppBuildIdentity.gitCommit(infoValue: "unknown") == nil)
        #expect(AppBuildIdentity.gitCommit(infoValue: "OPPI_GIT_COMMIT_VALUE") == nil)
        #expect(AppBuildIdentity.gitCommit(infoValue: "fdf98184568b") == "fdf98184568b")
        #expect(AppBuildIdentity.gitCommit(infoValue: "FDF98184568B-dirty") == "fdf98184568b-dirty")
    }

    @Test func splitDetailPushChangesDepthAndEmitsWhenScreenTokenIsUnchanged() {
        let navigation = AppNavigation()
        navigation.launchPhase = .ready
        navigation.showOnboarding = false
        navigation.setWorkspaceNavigationPresentation(.split)
        navigation.openChatReader(ChatReaderNavTarget(id: UUID()))

        let before = navigation.navigationRouteSnapshot
        #expect(before.screen == "chat_reader")
        #expect(before.presentation == "split")
        #expect(before.stackDepth == 1)
        #expect(navigation.visibleSplitDiagnosticContext.screen == "chat_reader")

        navigation.openChatReader(ChatReaderNavTarget(id: UUID()))
        let after = navigation.navigationRouteSnapshot

        #expect(after.screen == before.screen)
        #expect(navigation.visibleSplitDiagnosticContext == WorkspaceStackDiagnosticContext(
            screen: "chat_reader",
            sessionId: nil,
            workspaceId: nil
        ))
        #expect(after.stackDepth == before.stackDepth + 1)
        #expect(after.stackDepth == 2)

        var logs: [NavigationRouteLog] = []
        let coalescer = NavigationRouteTelemetryCoalescer(
            schedule: { _ in },
            emit: { logs.append($0) }
        )
        coalescer.note(before)
        coalescer.flush()
        coalescer.note(after)
        coalescer.flush()

        #expect(logs.count == 2)
        #expect(logs[1].message == "Route changed")
        #expect(logs[1].metadata["screen"] == "chat_reader")
        #expect(logs[1].metadata["previousScreen"] == "chat_reader")
        #expect(logs[1].metadata["stackDepth"] == "2")
        #expect(logs[1].metadata["presentation"] == "split")
    }
}
