import Foundation
import Testing
import UserNotifications
@testable import Oppi

@Suite("Remote push", .serialized)
@MainActor
struct RemotePushTests {
    // MARK: - APNs environment

    private func provisioningProfile(apsEnvironment: String?) throws -> Data {
        var entitlements: [String: Any] = ["application-identifier": "TEAM.dev.chenda.Oppi"]
        if let apsEnvironment { entitlements["aps-environment"] = apsEnvironment }
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["Name": "iOS Team Provisioning Profile", "Entitlements": entitlements],
            format: .xml,
            options: 0
        )
        // A real profile wraps the plist in a binary CMS signature.
        return Data([0x30, 0x82, 0x3C, 0x3F, 0x00]) + plist + Data([0xA0, 0x82, 0x01, 0x00])
    }

    @Test func profileEnvironmentMapsToTheAPNsHost() throws {
        #expect(APNsEnvironment.fromProvisioningProfile(try provisioningProfile(apsEnvironment: "development")) == .sandbox)
        #expect(APNsEnvironment.fromProvisioningProfile(try provisioningProfile(apsEnvironment: "production")) == .production)
    }

    @Test func profileWithoutPushHasNoEnvironment() throws {
        #expect(APNsEnvironment.fromProvisioningProfile(try provisioningProfile(apsEnvironment: nil)) == nil)
        #expect(APNsEnvironment.fromProvisioningProfile(Data("not a profile".utf8)) == nil)
    }

    // MARK: - Local done banner

    private func working(_ id: String = "s1", parent: String? = nil) -> Session {
        var session = makeTestSession(
            id: id,
            workspaceId: "w1",
            name: "Fix login",
            status: .busy,
            programStatus: ProgramStatus(state: .working, since: Date(timeIntervalSince1970: 1))
        )
        session.parentSessionId = parent
        return session
    }

    private func finished(_ session: Session) -> Session {
        var done = session
        done.status = .ready
        done.programStatus = ProgramStatus(state: .done, since: Date(timeIntervalSince1970: 2))
        return done
    }

    @Test func onlyATopLevelSessionEnteringDoneCounts() {
        let session = working()
        #expect(AttentionNotificationPolicy.enteredDone(previous: session, current: finished(session)))
        #expect(!AttentionNotificationPolicy.enteredDone(previous: finished(session), current: finished(session)))
        #expect(!AttentionNotificationPolicy.enteredDone(previous: nil, current: finished(session)))

        let child = working("child", parent: "s1")
        #expect(!AttentionNotificationPolicy.enteredDone(previous: child, current: finished(child)))
    }

    /// Delivers the request a `working -> done` app-event summary schedules, or nil.
    private func doneBanner(serverPushes: Bool) async -> DeliveredBanner? {
        let connection = ServerConnection()
        _ = connection.configure(credentials: makeTestCredentials(fingerprint: "sha256:push-srv"))
        connection.setSplitStreamCapabilitiesForTesting(appEventStream: true, pushNotifications: serverPushes)
        let session = working()
        connection.sessionStore.upsert(session)

        let service = AttentionNotificationService.shared
        let previousState = service._applicationStateForTesting
        defer {
            service._applicationStateForTesting = previousState
            service._deliverForTesting = nil
            service._appLockEnabledForTesting = nil
        }
        service._applicationStateForTesting = .background
        service._appLockEnabledForTesting = false

        return await withCheckedContinuation { continuation in
            let once = DeliveredOnce(continuation)
            service._deliverForTesting = { once.resume(DeliveredBanner($0)) }
            connection.handleAppEvent(.sessionSummary(
                sessionId: "s1",
                workspaceId: "w1",
                emittedAt: 2,
                summary: SessionSummary(from: finished(session))
            ))
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                once.resume(nil)
            }
        }
    }

    @Test func backgroundedAppPostsTheDoneBannerItsPushingServerSkipped() async throws {
        let request = try #require(await doneBanner(serverPushes: true))

        #expect(request.identifier == "done-s1")
        #expect(request.category == AttentionNotificationPolicy.sessionDoneCategoryId)
        #expect(request.title == String(localized: "Session Done"))
        #expect(request.subtitle == "Fix login")
        #expect(request.interruptionLevel == .passive)
        #expect(request.sessionId == "s1")
    }

    @Test func serverWithoutPushKeepsDoneInApp() async {
        #expect(await doneBanner(serverPushes: false) == nil)
    }
}

/// The delivered request's fields; `UNNotificationRequest` is not Sendable.
private struct DeliveredBanner: Sendable, Equatable {
    let identifier: String
    let category: String
    let title: String
    let subtitle: String
    let interruptionLevel: UNNotificationInterruptionLevel
    let sessionId: String?

    init(_ request: UNNotificationRequest) {
        identifier = request.identifier
        category = request.content.categoryIdentifier
        title = request.content.title
        subtitle = request.content.subtitle
        interruptionLevel = request.content.interruptionLevel
        sessionId = request.content.userInfo["sessionId"] as? String
    }
}

/// Resumes a continuation once; later calls are ignored.
@MainActor
private final class DeliveredOnce {
    private var continuation: CheckedContinuation<DeliveredBanner?, Never>?

    init(_ continuation: CheckedContinuation<DeliveredBanner?, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: DeliveredBanner?) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}
