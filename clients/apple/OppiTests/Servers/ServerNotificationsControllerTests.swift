import Foundation
import Testing
@testable import Oppi

/// The Notifications section's per-server state: what the push switch shows while
/// `PushEnableFlow` runs, and what a Live Activities change leaves behind.
@Suite("Server notifications controller", .serialized)
@MainActor
struct ServerNotificationsControllerTests {
    private func makeDefaults() throws -> UserDefaults {
        let name = "ServerNotificationsControllerTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("Starts from this server's saved opt-ins, and another server's do not count")
    func startsFromThisServersOptIns() throws {
        let defaults = try makeDefaults()
        PushRegistration.setEnabled(true, serverId: "server-a", defaults: defaults)
        LiveActivitySettings.setEnabled(true, serverId: "server-b", defaults: defaults)

        let a = ServerNotificationsController(serverId: "server-a", defaults: defaults)
        let b = ServerNotificationsController(serverId: "server-b", defaults: defaults)

        #expect(a.pushEnabled)
        #expect(!a.liveActivityEnabled)
        #expect(!b.pushEnabled)
        #expect(b.liveActivityEnabled)
        #expect(a.pushStatus == .idle && a.pushFailure == nil && a.liveActivityStatus == .idle)
    }

    @Test("Turn-on steps: working shows the switch on and busy; enabled settles it; a failure puts it off with the reason")
    func pushTurnOnTransitions() throws {
        let controller = ServerNotificationsController(serverId: "server-a", defaults: try makeDefaults())

        controller.apply(.working)
        #expect(controller.pushEnabled)
        #expect(controller.pushStatus == .working)
        #expect(controller.pushFailure == nil)

        controller.apply(.enabled)
        #expect(controller.pushEnabled)
        #expect(controller.pushStatus == .idle)

        controller.apply(.working)
        controller.apply(.failed("Couldn't turn on push: the push relay is busy. Try again later."))
        #expect(!controller.pushEnabled)
        #expect(controller.pushStatus == .idle)
        #expect(controller.pushFailure == "Couldn't turn on push: the push relay is busy. Try again later.")

        // The next try clears the last failure.
        controller.apply(.working)
        #expect(controller.pushFailure == nil)
    }

    @Test("Cancelling the disclosure changes nothing but asks the switch to be drawn again")
    func cancelledDisclosureRedraws() throws {
        let controller = ServerNotificationsController(serverId: "server-a", defaults: try makeDefaults())
        let before = controller.redraws

        controller.apply(.cancelled)

        #expect(!controller.pushEnabled)
        #expect(controller.pushStatus == .idle)
        #expect(controller.redraws == before + 1)
    }

    @Test("A turn-on that failed before registering reads the same as one that failed after")
    func refusedTurnOnLeavesPushOff() throws {
        let controller = ServerNotificationsController(serverId: "server-a", defaults: try makeDefaults())

        controller.apply(.failed(ServerNotificationsSection.message(for: .refused)))

        #expect(!controller.pushEnabled)
        #expect(controller.pushFailure == "Couldn't turn on push: the server or the push relay didn't accept it. Try again later.")
    }

    @Test("Reload picks up a turn-on made elsewhere, but not while this one is working")
    func reloadFollowsTheOptIn() throws {
        let defaults = try makeDefaults()
        let controller = ServerNotificationsController(serverId: "server-a", defaults: defaults)
        #expect(!controller.pushEnabled)

        PushRegistration.setEnabled(true, serverId: "server-a", defaults: defaults)
        controller.reload()
        #expect(controller.pushEnabled)

        controller.apply(.working)
        PushRegistration.setEnabled(false, serverId: "server-a", defaults: defaults)
        controller.reload()
        #expect(controller.pushEnabled)
    }

    @Test("Live Activities without a connection are saved for this server and send nothing")
    func liveActivityWithoutConnection() throws {
        let defaults = try makeDefaults()
        let controller = ServerNotificationsController(serverId: "server-live", defaults: defaults)

        controller.setLiveActivity(true, connection: nil)
        #expect(controller.liveActivityEnabled)
        #expect(LiveActivitySettings.isEnabled(serverId: "server-live", defaults: defaults))
        #expect(controller.liveActivityStatus == .idle)

        controller.setLiveActivity(false, connection: nil)
        #expect(!controller.liveActivityEnabled)
        #expect(!LiveActivitySettings.isEnabled(serverId: "server-live", defaults: defaults))
    }
}
