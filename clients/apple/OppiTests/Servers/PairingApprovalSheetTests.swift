import Foundation
import Testing
import UIKit
@testable import Oppi

/// The pairing approval sheet and the controller behind it: Approve and Deny reach exactly the
/// request the sheet shows, on its own server; nothing is signed for an expired request or
/// without the owner's authentication; the sheet mirrors the controller's state in place.
@Suite("Pairing approval sheet", .serialized)
@MainActor
struct PairingApprovalSheetTests {
    private func approval(_ id: String, requestedAt: Int64 = 1, expiresAt: Int64 = 9_999_999_999_999) -> PendingPairingApproval {
        PendingPairingApproval(
            id: id, deviceName: "Alex's iPad", method: "invite", source: "100.64.0.7",
            requestedAt: requestedAt, expiresAt: expiresAt, keyThumbprint: "thumb"
        )
    }

    private func present(
        _ approvals: [PendingPairingApproval],
        on serverId: String = "sha256:s",
        now: Date = Date()
    ) -> PairingApprovalController {
        let controller = PairingApprovalController()
        controller.apply(
            pending: approvals.map { (serverId: serverId, serverName: "Mac", approval: $0) },
            now: now
        )
        return controller
    }

    // MARK: - Formatting

    @Test("A request whose time is up reads Expired, not In 0s")
    func expiryWords() {
        let now = Date(timeIntervalSince1970: 1_000)
        func ms(_ seconds: TimeInterval) -> Int64 { Int64(seconds * 1_000) }
        #expect(PairingApprovalPromptFormatting.expiry(ms(1_090), now: now) == "In 1:30")
        #expect(PairingApprovalPromptFormatting.expiry(ms(1_042), now: now) == "In 42s")
        #expect(PairingApprovalPromptFormatting.expiry(ms(1_000), now: now) == "Expired")
        #expect(PairingApprovalPromptFormatting.expiry(ms(900), now: now) == "Expired")
    }

    // MARK: - Approve

    @Test("A tap for a request the sheet is no longer showing approves nothing and asks for nothing")
    func staleTapIsIgnored() async {
        let controller = present([approval("pa_1", requestedAt: 1), approval("pa_2", requestedAt: 2)])
        #expect(controller.presented?.approval.id == "pa_1")
        var authentications = 0

        await controller.approve(
            presentedId: "sha256:s|pa_2", coordinator: ConnectionCoordinator(serverStore: ServerStore()),
            authenticate: { _ in authentications += 1; return true }
        )

        #expect(authentications == 0)
        #expect(controller.presented?.approval.id == "pa_1")
        #expect(controller.presented?.isBusy == false)
    }

    @Test("An expired request is never signed: no authentication is asked, and the sheet says why")
    func expiredIsNeverApproved() async {
        let now = Date()
        let expires = Int64(now.addingTimeInterval(30).timeIntervalSince1970 * 1_000)
        let controller = present([approval("pa_1", expiresAt: expires)], now: now)
        var authentications = 0

        await controller.approve(
            presentedId: "sha256:s|pa_1",
            coordinator: ConnectionCoordinator(serverStore: ServerStore()),
            now: { now.addingTimeInterval(31) },
            authenticate: { _ in authentications += 1; return true }
        )

        #expect(authentications == 0)
        #expect(controller.presented?.isBusy == false)
        #expect(controller.presented?.errorMessage == "This request expired. Ask the device to try again.")
    }

    @Test("A request that expires while the owner is authenticating is not signed")
    func expiresDuringAuthentication() async {
        let start = Date()
        let expires = Int64(start.addingTimeInterval(30).timeIntervalSince1970 * 1_000)
        let controller = present([approval("pa_1", expiresAt: expires)], now: start)
        var clock = start

        await controller.approve(
            presentedId: "sha256:s|pa_1",
            coordinator: ConnectionCoordinator(serverStore: ServerStore()),
            now: { clock },
            authenticate: { _ in
                clock = start.addingTimeInterval(45)
                return true
            }
        )

        #expect(controller.presented?.errorMessage == "This request expired. Ask the device to try again.")
        #expect(controller.presented?.isBusy == false)
    }

    @Test("Without the owner's authentication nothing is approved and the sheet is free again")
    func authenticationIsRequired() async {
        let controller = present([approval("pa_1")])

        await controller.approve(
            presentedId: "sha256:s|pa_1", coordinator: ConnectionCoordinator(serverStore: ServerStore()),
            authenticate: { _ in false }
        )

        #expect(controller.presented?.approval.id == "pa_1")
        #expect(controller.presented?.isBusy == false)
        #expect(controller.presented?.errorMessage == nil)
    }

    @Test("While the owner authenticates, the sheet reads busy")
    func busyWhileAuthenticating() async {
        let controller = present([approval("pa_1")])
        var busyDuring: Bool?

        await controller.approve(
            presentedId: "sha256:s|pa_1", coordinator: ConnectionCoordinator(serverStore: ServerStore()),
            authenticate: { _ in
                busyDuring = controller.presented?.isBusy
                return false
            }
        )

        #expect(busyDuring == true)
    }

    @Test("A request that leaves while the owner authenticates is not signed and leaves no stale sheet")
    func requestLeavingDuringAuthenticationWritesNothingBack() async {
        let controller = present([approval("pa_1")])

        await controller.approve(
            presentedId: "sha256:s|pa_1",
            coordinator: ConnectionCoordinator(serverStore: ServerStore()),
            authenticate: { _ in
                // Denied from another device while Face ID is up.
                controller.apply(pending: [])
                return true
            }
        )

        // Signing would have failed here ("That server is not connected.") and written the
        // old request back into the sheet.
        #expect(controller.presented == nil)
    }

    @Test("When another request takes the sheet during authentication, the owner's yes is not applied to it")
    func anotherRequestTakingTheSheetIsLeftAlone() async {
        let controller = present([approval("pa_1", requestedAt: 1)])

        await controller.approve(
            presentedId: "sha256:s|pa_1",
            coordinator: ConnectionCoordinator(serverStore: ServerStore()),
            authenticate: { _ in
                controller.apply(pending: [(serverId: "sha256:s", serverName: "Mac", approval: self.approval("pa_2", requestedAt: 2))])
                return true
            }
        )

        #expect(controller.presented?.approval.id == "pa_2")
        #expect(controller.presented?.isBusy == false)
        #expect(controller.presented?.errorMessage == nil)
    }

    @Test("A second Approve tap while the first is authenticating asks for nothing more")
    func doubleTapAuthenticatesOnce() async {
        let controller = present([approval("pa_1")])
        let coordinator = ConnectionCoordinator(serverStore: ServerStore())
        var authentications = 0
        var release: CheckedContinuation<Bool, Never>?
        let first = Task {
            await controller.approve(presentedId: "sha256:s|pa_1", coordinator: coordinator, authenticate: { _ in
                authentications += 1
                return await withCheckedContinuation { release = $0 }
            })
        }
        #expect(await waitForMainActorCondition { release != nil })

        await controller.approve(presentedId: "sha256:s|pa_1", coordinator: coordinator, authenticate: { _ in
            authentications += 1
            return true
        })

        #expect(authentications == 1)
        #expect(controller.presented?.isBusy == true)
        release?.resume(returning: false)
        await first.value
        #expect(controller.presented?.isBusy == false)
    }

    // MARK: - Deny

    @Test("Deny queues exactly the presented request on its own server, not the same id on another")
    func denyTargetsThePresentedServer() async {
        // The same approval id on two servers; server A's is older, so it is the one shown.
        let controller = PairingApprovalController()
        controller.apply(pending: [
            (serverId: "server-b", serverName: "B", approval: approval("pa_1", requestedAt: 2)),
            (serverId: "server-a", serverName: "A", approval: approval("pa_1", requestedAt: 1)),
        ])
        #expect(controller.presented?.id == "server-a|pa_1")

        // No connection to send it through, so the deny stays queued where it was aimed.
        await controller.deny(presentedId: "server-a|pa_1", coordinator: ConnectionCoordinator(serverStore: ServerStore()))

        #expect(controller.hasQueuedDeny(serverId: "server-a", approvalId: "pa_1"))
        #expect(!controller.hasQueuedDeny(serverId: "server-b", approvalId: "pa_1"))
    }

    @Test("A Deny tap for a request the sheet moved past does nothing")
    func staleDenyIsIgnored() async {
        let controller = present([approval("pa_1", requestedAt: 1), approval("pa_2", requestedAt: 2)])

        await controller.deny(presentedId: "sha256:s|pa_2", coordinator: ConnectionCoordinator(serverStore: ServerStore()))

        #expect(controller.presented?.id == "sha256:s|pa_1")
        #expect(!controller.hasQueuedDeny(serverId: "sha256:s", approvalId: "pa_2"))
    }

    // MARK: - The sheet

    private func presentSheet(_ controller: PairingApprovalController) async throws -> (anchor: UIViewController, window: UIWindow, presentation: PairingApprovalPresentation) {
        let root = makeTestAppRoot()
        let anchor = UIViewController()
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = anchor
        window.makeKeyAndVisible()
        let presentation = PairingApprovalPresentation(controller: controller, root: root, anchor: anchor)
        presentation.update()
        presentation.anchorDidAppear()
        return (anchor, window, presentation)
    }

    private func sheet(on anchor: UIViewController) -> PairingApprovalViewController? {
        (anchor.presentedViewController as? UINavigationController)?.viewControllers.first as? PairingApprovalViewController
    }

    private static func button(_ identifier: String, in view: UIView) -> UIButton? {
        if let button = view as? UIButton, button.accessibilityIdentifier == identifier { return button }
        for subview in view.subviews {
            if let found = button(identifier, in: subview) { return found }
        }
        return nil
    }

    private static func label(_ identifier: String, in view: UIView) -> UILabel? {
        if let label = view as? UILabel, label.accessibilityIdentifier == identifier { return label }
        for subview in view.subviews {
            if let found = label(identifier, in: subview) { return found }
        }
        return nil
    }

    @Test("The sheet presents for the pending request, mirrors busy and errors in place, and goes when the request does")
    func sheetMirrorsTheController() async throws {
        let controller = present([approval("pa_1")])
        let (anchor, window, presentation) = try await presentSheet(controller)
        defer { window.isHidden = true; window.rootViewController = nil }
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { sheet(on: anchor) != nil })
        let shown = try #require(sheet(on: anchor))
        shown.loadViewIfNeeded()
        let approve = try #require(Self.button("pairing.approval.approve", in: shown.view))
        #expect(approve.isEnabled)
        #expect(!shown.isModalInPresentation)

        // Busy: the owner is authenticating. The same sheet, now held, with Approve off.
        var release: CheckedContinuation<Bool, Never>?
        let coordinator = ConnectionCoordinator(serverStore: ServerStore())
        let approving = Task {
            await controller.approve(presentedId: "sha256:s|pa_1", coordinator: coordinator, authenticate: { _ in
                await withCheckedContinuation { release = $0 }
            })
        }
        #expect(await waitForMainActorCondition { release != nil })
        presentation.update()
        shown.view.layoutIfNeeded()
        #expect(sheet(on: anchor) === shown)
        #expect(shown.isModalInPresentation)
        #expect(shown.navigationController?.isModalInPresentation == true)
        #expect(!approve.isEnabled)
        release?.resume(returning: false)
        await approving.value

        // A failure: still the same sheet, with the reason and the buttons back.
        await controller.approve(
            presentedId: "sha256:s|pa_1", coordinator: coordinator,
            now: { Date(timeIntervalSince1970: 10_000_000_000) },
            authenticate: { _ in true }
        )
        presentation.update()
        shown.view.layoutIfNeeded()
        #expect(sheet(on: anchor) === shown)
        #expect(!shown.isModalInPresentation)
        #expect(approve.isEnabled)
        #expect(shown.presented.errorMessage == "This request expired. Ask the device to try again.")
        let error = try #require(Self.label("pairing.approval.error", in: shown.view))
        #expect(error.text == "This request expired. Ask the device to try again.")

        // The request is gone (denied elsewhere, expired): the sheet goes.
        controller.apply(pending: [])
        presentation.update()
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { anchor.presentedViewController == nil })
    }

    @Test("A sheet for a request that is already expired cannot approve")
    func expiredSheetDisablesApprove() async throws {
        let now = Date()
        let controller = present([approval("pa_1", expiresAt: Int64(now.addingTimeInterval(60).timeIntervalSince1970 * 1_000))], now: now)
        let presented = try #require(controller.presented)
        let root = makeTestAppRoot()
        // The same request, as the sheet sees it after its time has passed.
        let late = PairingApprovalController.Presented(
            serverId: presented.serverId, serverName: presented.serverName,
            approval: approval("pa_1", expiresAt: Int64(now.addingTimeInterval(-5).timeIntervalSince1970 * 1_000)),
            errorMessage: nil, isBusy: false
        )
        let sheet = PairingApprovalViewController(presented: late, controller: controller, root: root)
        sheet.loadViewIfNeeded()
        sheet.view.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        sheet.view.layoutIfNeeded()
        sheet.updateProperties()

        #expect(Self.button("pairing.approval.approve", in: sheet.view)?.isEnabled == false)
        #expect(Self.button("pairing.approval.deny", in: sheet.view)?.isEnabled == true)
    }

    @Test("A newer state of a different request is not the sheet's to show")
    func sheetIgnoresAnotherRequest() throws {
        let controller = present([approval("pa_1")])
        let sheet = PairingApprovalViewController(
            presented: try #require(controller.presented), controller: controller, root: makeTestAppRoot()
        )
        var other = try #require(controller.presented)
        other = PairingApprovalController.Presented(
            serverId: other.serverId, serverName: other.serverName, approval: approval("pa_9"), errorMessage: "x", isBusy: true
        )

        sheet.apply(other)

        #expect(sheet.presented.approval.id == "pa_1")
        #expect(!sheet.presented.isBusy)
    }
}
