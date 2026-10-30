import Foundation
import Testing
import UIKit
@testable import Oppi

/// The shell's own workspace creation: the rules `WorkspaceCreationIntake` and its
/// owner (`AppRootViewController`) keep, with the server refresh stubbed out.
@MainActor
@Suite("Workspace creation intake")
struct WorkspaceCreationIntakeTests {
    private func server(_ name: String) throws -> PairedServer {
        try #require(PairedServer(from: ServerCredentials(
            host: "\(name).intake.test",
            port: 7749,
            token: "sk_test",
            name: name,
            scheme: .https,
            serverFingerprint: "sha256:intake-\(name)",
            tlsCertFingerprint: "sha256:intake-\(name)-leaf"
        )))
    }

    /// A root whose coordinator has `servers` paired and the first active.
    private func makeRoot(servers: [PairedServer]) -> AppRootEnvironment {
        let serverStore = ServerStore()
        serverStore.replaceServersForPreview(servers)
        let coordinator = ConnectionCoordinator(serverStore: serverStore)
        #expect(coordinator.restoreActiveServer(servers[0].id))
        return makeTestAppRoot(coordinator: coordinator)
    }

    /// Records each refresh; one that is told to hang waits until its task is cancelled.
    @MainActor
    private final class RefreshRecorder {
        var started: [String] = []
        var cancelled: [String] = []
        var hanging: Set<String> = []

        func refresh(_ serverId: String) async {
            started.append(serverId)
            guard hanging.contains(serverId) else { return }
            await withTaskCancellationHandler {
                while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
            } onCancel: {
                Task { @MainActor in self.cancelled.append(serverId) }
            }
        }
    }

    private func makeIntake(
        root: AppRootEnvironment,
        recorder: RefreshRecorder = RefreshRecorder()
    ) -> (intake: WorkspaceCreationIntake, anchor: UIViewController, recorder: RefreshRecorder) {
        let anchor = UIViewController()
        let intake = WorkspaceCreationIntake(
            root: root,
            anchor: anchor,
            refreshServer: { await recorder.refresh($0) }
        )
        return (intake, anchor, recorder)
    }

    @Test("a workspace link parked while the shell shows opens a prefilled create sheet that stays on the shell")
    func workspaceLinkOpensPrefilledSheet() async throws {
        let alpha = try server("alpha")
        let root = makeRoot(servers: [alpha])
        let (intake, _, _) = makeIntake(root: root)
        intake.update()

        root.navigation.pendingWorkspaceDeepLink = WorkspaceDeepLink.Payload(
            path: "/srv/repo", name: "Repo", serverFingerprint: nil
        ).resolved(on: alpha.id)
        intake.update()

        #expect(await waitForMainActorCondition { intake.createSheetContext != nil })
        let context = try #require(intake.createSheetContext)
        #expect(context.server.id == alpha.id)
        #expect(context.prefillName == "Repo")
        #expect(context.prefillPath == "/srv/repo")
        #expect(context.presentation == .standard)
        #expect(!context.openWorkspaceAfterCreate)
        #expect(root.navigation.pendingWorkspaceDeepLink == nil)
    }

    @Test("a link already parked when the shell mounts is consumed on mount")
    func linkParkedBeforeMountIsConsumed() async throws {
        let alpha = try server("alpha")
        let root = makeRoot(servers: [alpha])
        root.navigation.pendingWorkspaceDeepLink = WorkspaceDeepLink.Payload(
            path: "/srv/early", name: nil, serverFingerprint: nil
        ).resolved(on: alpha.id)
        let (intake, _, _) = makeIntake(root: root)
        intake.update()

        #expect(await waitForMainActorCondition { intake.createSheetContext != nil })
        #expect(intake.createSheetContext?.prefillPath == "/srv/early")
    }

    @Test("a link whose server is gone shows a notice and opens no sheet")
    func linkForUnknownServerShowsNotice() async throws {
        let alpha = try server("alpha")
        let root = makeRoot(servers: [alpha])
        let (intake, _, _) = makeIntake(root: root)
        intake.update()

        root.navigation.pendingWorkspaceDeepLink = WorkspaceDeepLink.Payload(
            path: "/srv/repo", name: nil, serverFingerprint: nil
        ).resolved(on: "sha256:removed")
        intake.update()

        #expect(await waitForMainActorCondition { root.navigation.pendingWorkspaceDeepLink == nil })
        #expect(root.coordinator.activeConnection.extensionToast == "Server not found for this workspace link")
        #expect(intake.createSheetContext == nil)
    }

    @Test("guided creation opens once for an empty server and not again until the shell remounts")
    func guidedCreationIsOncePerShell() async throws {
        let alpha = try server("alpha")
        let root = makeRoot(servers: [alpha])
        let (intake, _, recorder) = makeIntake(root: root)
        root.navigation.shouldGuideWorkspaceCreation = true
        intake.update()

        #expect(await waitForMainActorCondition { intake.createSheetContext != nil })
        let context = try #require(intake.createSheetContext)
        #expect(context.presentation == .guidedFirstWorkspace)
        #expect(context.openWorkspaceAfterCreate)
        #expect(!root.navigation.shouldGuideWorkspaceCreation)
        #expect(recorder.started == [alpha.id])

        // Asked for again within the same shell: consumed, so it never refreshes or reopens.
        root.navigation.shouldGuideWorkspaceCreation = true
        intake.update()
        root.navigation.shouldGuideWorkspaceCreation = false
        intake.update()
        root.navigation.shouldGuideWorkspaceCreation = true
        intake.update()
        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(150)) { recorder.started.count == 1 })

        // The owner drops the intake when the shell unmounts; the next shell starts over.
        let (remounted, _, remountRecorder) = makeIntake(root: root)
        root.navigation.shouldGuideWorkspaceCreation = true
        remounted.update()
        #expect(await waitForMainActorCondition { remounted.createSheetContext != nil })
        #expect(remountRecorder.started == [alpha.id])
    }

    @Test("a server that already has workspaces ends the guide without a sheet")
    func guidedCreationSkipsServersWithWorkspaces() async throws {
        let alpha = try server("alpha")
        let root = makeRoot(servers: [alpha])
        let connection = try #require(root.coordinator.connection(for: alpha.id))
        connection.workspaceStore.workspaces = [makeTestWorkspace(id: "w1")]
        let (intake, _, recorder) = makeIntake(root: root)
        root.navigation.shouldGuideWorkspaceCreation = true
        intake.update()

        #expect(await waitForMainActorCondition { !root.navigation.shouldGuideWorkspaceCreation })
        #expect(recorder.started == [alpha.id])
        #expect(intake.createSheetContext == nil)
    }

    @Test("switching servers cancels the intake run for the old server and starts one for the new")
    func serverSwitchCancelsThePreviousRun() async throws {
        let alpha = try server("alpha")
        let beta = try server("beta")
        let root = makeRoot(servers: [alpha, beta])
        let recorder = RefreshRecorder()
        recorder.hanging = [alpha.id]
        // Already guiding when the shell mounts, so only the per-server run starts.
        root.navigation.shouldGuideWorkspaceCreation = true
        let (intake, _, _) = makeIntake(root: root, recorder: recorder)
        intake.update()
        #expect(await waitForMainActorCondition { recorder.started == [alpha.id] })
        let first = try #require(intake.intakeTask)

        // Unrelated updates do not restart it.
        intake.update()
        #expect(intake.intakeTask == first)
        #expect(recorder.cancelled.isEmpty)

        #expect(root.coordinator.restoreActiveServer(beta.id))
        intake.update()

        #expect(await waitForMainActorCondition { recorder.cancelled == [alpha.id] })
        #expect(await waitForMainActorCondition { recorder.started == [alpha.id, beta.id] })
        #expect(await waitForMainActorCondition { intake.createSheetContext?.server.id == beta.id })
    }

    @Test("the root keeps an intake only while it shows the shell, and a remounted shell gets a fresh one")
    func theRootOwnsTheIntakeWhileTheShellShows() throws {
        let app = OppiApp()
        let controller = AppRootViewController(app: app)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let navigation = app.root.navigation

        func render() {
            controller.view.layoutIfNeeded()
            controller.updatePropertiesIfNeeded()
        }

        render()
        #expect(navigation.launchPhase == .resolving)
        #expect(controller.workspaceCreation == nil)

        navigation.launchPhase = .ready
        navigation.showOnboarding = true
        render()
        #expect(controller.workspaceCreation == nil, "onboarding is not the shell")

        navigation.showOnboarding = false
        render()
        let first = try #require(controller.workspaceCreation)

        navigation.showOnboarding = true
        render()
        #expect(controller.workspaceCreation == nil)

        navigation.showOnboarding = false
        render()
        let second = try #require(controller.workspaceCreation)
        #expect(second !== first)
    }
}
