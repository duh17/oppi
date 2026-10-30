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

    @Test("guided creation opens once for an empty server and not again within the shell")
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

    @Test("a stopped intake does nothing when its server refresh returns")
    func stoppedIntakeIgnoresALateRefresh() async throws {
        let alpha = try server("alpha")
        let root = makeRoot(servers: [alpha])
        let recorder = RefreshRecorder()
        recorder.hanging = [alpha.id]
        root.navigation.shouldGuideWorkspaceCreation = true
        let (intake, _, _) = makeIntake(root: root, recorder: recorder)
        intake.update()
        #expect(await waitForMainActorCondition { recorder.started == [alpha.id] })

        // The shell goes while the refresh is out; the refresh then returns.
        intake.stop()
        #expect(await waitForMainActorCondition { recorder.cancelled == [alpha.id] })

        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(150)) {
            intake.createSheetContext == nil && root.navigation.shouldGuideWorkspaceCreation
        })
    }

    @Test("the root holds an intake only while the shell shows, and a remounted shell gets a fresh one")
    func theRootHoldsTheIntakeWhileTheShellShows() throws {
        let root = makeRoot(servers: [try server("alpha")])
        let anchor = UIViewController()
        let holder = WorkspaceCreationIntakeHolder()

        holder.update(showsShell: false, root: root, anchor: anchor)
        #expect(holder.intake == nil, "launching and onboarding are not the shell")

        holder.update(showsShell: true, root: root, anchor: anchor)
        let first = try #require(holder.intake)
        holder.update(showsShell: true, root: root, anchor: anchor)
        #expect(holder.intake === first, "an update keeps the shell's intake")

        holder.update(showsShell: false, root: root, anchor: anchor)
        #expect(holder.intake == nil)

        holder.update(showsShell: true, root: root, anchor: anchor)
        #expect(holder.intake !== first)
    }
}
