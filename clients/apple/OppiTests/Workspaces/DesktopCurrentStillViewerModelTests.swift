import Foundation
import Testing
import UIKit
@testable import Oppi

// swiftlint:disable force_unwrapping

@Suite("Desktop current still viewer model")
@MainActor
struct DesktopCurrentStillViewerModelTests {
    private let png = Data(
        base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
    )!

    @Test func startsInLoading() {
        let model = DesktopCurrentStillViewerModel {
            Issue.record("fetch should not run until load")
            throw APIError.invalidResponse
        }

        #expect(model.phase == .loading)
        #expect(model.still == nil)
        #expect(model.viewGrantStatus == .none)
        #expect(model.isLoading)
        #expect(!model.canRetry)
    }

    @Test func loadExposesStillMetadataWithoutTreatingItAsLive() async throws {
        let capturedAt = Date(timeIntervalSince1970: 1_778_212_840)
        let still = makeStill(capturedAt: capturedAt)
        let model = DesktopCurrentStillViewerModel { still }

        await model.load()

        let loaded = try #require(model.still)
        #expect(model.phase == .loaded(still))
        #expect(loaded.caption == DesktopCurrentStillHeaders.stillCaption)
        #expect(loaded.caption == "Still—not live")
        #expect(loaded.surfaceTitle == "Notes")
        #expect(loaded.capturedAt == capturedAt)
        #expect(loaded.pngData == png)
        #expect(model.viewGrantStatus == .none)
        #expect(model.canRetry)
        #expect(!model.isLoading)
    }

    @Test func mapsForbiddenToRemoteViewOff() {
        assertMappedFailure(
            APIError.server(status: 403, message: "Desktop still sharing is disabled"),
            expected: .remoteViewOff,
            forbiddenTokens: ["403", "HTTP"]
        )
        assertMappedFailure(
            APIError.codedServer(
                status: 403,
                message: "Desktop still sharing is disabled",
                code: "sharing_disabled"
            ),
            expected: .remoteViewOff,
            forbiddenTokens: ["403"]
        )
    }

    @Test func mapsMissingToNoneAvailable() {
        assertMappedFailure(
            APIError.server(status: 404, message: "Desktop still is not available"),
            expected: .noneAvailable,
            forbiddenTokens: ["404", "HTTP"]
        )
    }

    @Test func mapsCompanionDown() {
        assertMappedFailure(
            APIError.server(status: 502, message: "Desktop companion is unavailable"),
            expected: .companionDown,
            forbiddenTokens: ["502", "HTTP"]
        )
    }

    @Test func loadFailureUsesGrantCopyInsteadOfStatusCode() async throws {
        let model = DesktopCurrentStillViewerModel {
            throw APIError.server(status: 403, message: "Desktop still sharing is disabled")
        }

        await model.load()

        #expect(model.still == nil)
        #expect(model.phase == .failed(.remoteViewOff))
        #expect(model.canRetry)
        let message = try #require(model.failure?.message)
        #expect(message.localizedCaseInsensitiveContains("remote view"))
        #expect(!message.contains("403"))
    }

    @Test func refreshDoesNotKeepStaleImageOnFailure() async throws {
        let script = FetchScript(first: makeStill(), failure: APIError.server(
            status: 404,
            message: "Desktop still is not available"
        ))
        let model = DesktopCurrentStillViewerModel { try await script.next() }

        await model.load()
        #expect(try #require(model.still).surfaceTitle == "Notes")
        #expect(await script.calls == 1)

        await model.refresh()

        #expect(await script.calls == 2)
        #expect(model.still == nil)
        #expect(model.phase == .failed(.noneAvailable))
        #expect(model.failure?.message.contains("404") == false)
        #expect(model.canRetry)
    }

    @Test func refreshClearsStillBeforeCompanionDown() async throws {
        let script = FetchScript(first: makeStill(), failure: APIError.server(
            status: 502,
            message: "Desktop companion is unavailable"
        ))
        let model = DesktopCurrentStillViewerModel { try await script.next() }

        await model.load()
        await model.refresh()

        #expect(model.still == nil)
        #expect(model.phase == .failed(.companionDown))
        let message = try #require(model.failure?.message)
        #expect(message.localizedCaseInsensitiveContains("companion"))
        #expect(!message.contains("502"))
    }

    @Test func cancelledRefreshKeepsPreviousStill() async throws {
        let script = FetchScript(first: makeStill(), failure: CancellationError())
        let model = DesktopCurrentStillViewerModel { try await script.next() }

        await model.load()
        let loaded = try #require(model.still)
        await model.refresh()

        #expect(await script.calls == 2)
        #expect(model.still?.captureID == loaded.captureID)
        #expect(model.phase == .loaded(loaded))
        #expect(model.canRetry)
        #expect(!model.isLoading)
    }

    @Test func cancelledInitialLoadBecomesFailedAndRetryable() async {
        let model = DesktopCurrentStillViewerModel {
            throw CancellationError()
        }

        await model.load()

        #expect(model.still == nil)
        #expect(model.phase == .failed(.unavailable))
        #expect(model.canRetry)
    }

    @Test func refreshOnlyRefetchesCurrentStill() async {
        let script = FetchScript(first: makeStill())
        let model = DesktopCurrentStillViewerModel { try await script.next() }

        await model.load()
        await model.refresh()

        #expect(await script.calls == 2)
        #expect(model.still != nil)
    }

    @Test func viewGrantStatusIsIndependentOfStillFetch() async throws {
        let expiresAt = Date(timeIntervalSince1970: 1_778_213_740)
        let stillScript = FetchScript(first: makeStill())
        let grantScript = ViewSessionScript(first: makeViewSession(expiresAt: expiresAt))
        let model = DesktopCurrentStillViewerModel {
            try await stillScript.next()
        } fetchViewSession: {
            try await grantScript.next()
        }

        await model.load()

        #expect(model.still != nil)
        #expect(model.viewGrantStatus == .granted(expiresAt: expiresAt))
        #expect(model.viewGrantStatus.message.hasPrefix("Granted to this device until"))
        #expect(!model.viewGrantStatus.message.localizedCaseInsensitiveContains("live viewing"))
        #expect(await stillScript.calls == 1)
        #expect(await grantScript.calls == 1)
    }

    @Test func stillForbiddenStillShowsGrantedStatus() async throws {
        let expiresAt = Date(timeIntervalSince1970: 1_778_213_740)
        let model = DesktopCurrentStillViewerModel {
            throw APIError.server(status: 403, message: "Desktop still sharing is disabled")
        } fetchViewSession: {
            makeViewSession(expiresAt: expiresAt)
        }

        await model.load()

        #expect(model.phase == .failed(.remoteViewOff))
        #expect(model.viewGrantStatus == .granted(expiresAt: expiresAt))
        #expect(!model.viewGrantStatus.message.contains("403"))
    }

    @Test func mapsViewGrantNoneAndNotGrantedWithoutLiveCopy() async throws {
        let still = makeStill()
        let noneModel = DesktopCurrentStillViewerModel {
            still
        } fetchViewSession: {
            throw APIError.codedServer(
                status: 403,
                message: "Desktop view session is not available",
                code: "view_grant_unavailable"
            )
        }
        await noneModel.load()
        #expect(noneModel.still?.captureID == still.captureID)
        #expect(noneModel.viewGrantStatus == .none)
        #expect(noneModel.viewGrantStatus.message == "No view session.")
        #expect(!noneModel.viewGrantStatus.message.localizedCaseInsensitiveContains("live viewing"))

        let notGranted = DesktopCurrentStillViewerModel {
            still
        } fetchViewSession: {
            throw APIError.codedServer(
                status: 403,
                message: "Desktop view session is not granted to this device",
                code: "view_grant_not_bound"
            )
        }
        await notGranted.load()
        #expect(notGranted.still?.captureID == still.captureID)
        #expect(notGranted.viewGrantStatus == .notGranted)
        #expect(notGranted.viewGrantStatus.message == "View session is not granted to this device.")
        #expect(!notGranted.viewGrantStatus.message.contains("403"))
        #expect(!notGranted.viewGrantStatus.message.localizedCaseInsensitiveContains("live viewing"))
    }

    @Test func refreshRefetchesViewGrantStatusLikeStill() async throws {
        let firstExpiry = Date(timeIntervalSince1970: 1_778_213_740)
        let secondExpiry = Date(timeIntervalSince1970: 1_778_214_640)
        let stillScript = FetchScript(first: makeStill())
        let grantScript = ViewSessionScript(
            first: makeViewSession(expiresAt: firstExpiry),
            second: makeViewSession(expiresAt: secondExpiry)
        )
        let model = DesktopCurrentStillViewerModel {
            try await stillScript.next()
        } fetchViewSession: {
            try await grantScript.next()
        }

        await model.load()
        #expect(model.viewGrantStatus == .granted(expiresAt: firstExpiry))
        await model.refresh()
        #expect(await stillScript.calls == 2)
        #expect(await grantScript.calls == 2)
        #expect(model.viewGrantStatus == .granted(expiresAt: secondExpiry))
    }

    @Test func cancelledRefreshKeepsPreviousViewGrantStatus() async throws {
        let expiresAt = Date(timeIntervalSince1970: 1_778_213_740)
        let stillScript = FetchScript(first: makeStill(), failure: CancellationError())
        let grantScript = ViewSessionScript(first: makeViewSession(expiresAt: expiresAt))
        let model = DesktopCurrentStillViewerModel {
            try await stillScript.next()
        } fetchViewSession: {
            try await grantScript.next()
        }

        await model.load()
        await model.refresh()

        #expect(model.still != nil)
        #expect(model.viewGrantStatus == .granted(expiresAt: expiresAt))
        #expect(await grantScript.calls == 1)
    }

    @Test func desktopStillUtilityIsPhoneOnlyAndReleaseEnabled() {
        #expect(WorkspaceUtilityNavTarget.desktopStill.isReleaseEnabled)

        let shared = WorkspaceSidebarPrimaryUtilities.items
        #expect(shared.map(\.target) == [.agents, .schedules, .skills, .extensions])

        let phone = WorkspaceSidebarPrimaryUtilities.items(for: .phone)
        #expect(phone.map(\.target) == [.agents, .schedules, .skills, .extensions, .desktopStill])
        #expect(phone.last?.title == "Mac Still")
        #expect(phone.last?.systemImage == "macwindow")
        #expect(phone.last?.accessibilityIdentifier == "workspace.desktopStill.open")
        #expect(phone.last?.minimumHitHeight == 44)
        #expect(phone.last?.accessibilityHint == "Inspect the current Mac still")

        let pad = WorkspaceSidebarPrimaryUtilities.items(for: .pad)
        #expect(pad.map(\.target) == [.agents, .schedules, .skills, .extensions])
        #expect(!pad.map(\.target).contains(.desktopStill))
    }

    @Test func desktopStillUtilityPushesOnStackWithDiagnostics() {
        let navigation = AppNavigation()
        navigation.launchPhase = .ready
        navigation.showOnboarding = false

        navigation.openWorkspaceUtility(.desktopStill)

        #expect(navigation.selectedTab == .workspaces)
        #expect(navigation.workspacePath.count == 1)
        #expect(navigation.workspaceStackDiagnosticContext.screen == "utility_desktop_still")
    }

    private func assertMappedFailure(
        _ error: Error,
        expected: DesktopCurrentStillViewerFailure,
        forbiddenTokens: [String]
    ) {
        let failure = DesktopCurrentStillViewerFailure(error)
        #expect(failure == expected)
        for token in forbiddenTokens {
            #expect(!failure.message.contains(token))
        }
        #expect(!failure.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func makeStill(capturedAt: Date = Date(timeIntervalSince1970: 1_778_212_840)) -> DesktopCurrentStill {
        DesktopCurrentStill(
            captureID: UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!,
            surfaceWindowID: 91,
            surfaceTitle: "Notes",
            capturedAt: capturedAt,
            width: 1,
            height: 1,
            caption: DesktopCurrentStillHeaders.stillCaption,
            pngData: png
        )
    }

    private func makeViewSession(expiresAt: Date) -> DesktopViewSession {
        DesktopViewSession(
            grantId: UUID(uuidString: "bbbbbbbb-cccc-4ddd-8eee-ffffffffffff")!,
            capability: DesktopViewSessionJSON.capabilityView,
            deviceId: "phone-1",
            expiresAt: expiresAt,
            caption: DesktopViewSessionJSON.caption
        )
    }
}

private actor FetchScript {
    private let first: DesktopCurrentStill
    private let failure: Error?
    private(set) var calls = 0

    init(first: DesktopCurrentStill, failure: Error? = nil) {
        self.first = first
        self.failure = failure
    }

    func next() async throws -> DesktopCurrentStill {
        calls += 1
        if calls == 1 {
            return first
        }
        if let failure {
            throw failure
        }
        return first
    }
}

private actor ViewSessionScript {
    private let first: DesktopViewSession
    private let second: DesktopViewSession?
    private(set) var calls = 0

    init(first: DesktopViewSession, second: DesktopViewSession? = nil) {
        self.first = first
        self.second = second
    }

    func next() async throws -> DesktopViewSession {
        calls += 1
        if calls == 1 {
            return first
        }
        return second ?? first
    }
}
