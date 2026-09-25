import Foundation
import Testing
@testable import Oppi

@Suite("Server release version")
struct ServerReleaseVersionTests {
    @Test func minimumSupportedIs0500() {
        #expect(ServerReleaseVersion.minimumSupported == "0.50.0")
    }

    @Test func treatsOlderServersAsBelowMinimum() {
        #expect(ServerReleaseVersion.isBelowMinimum("0.49.1"))
        #expect(ServerReleaseVersion.isBelowMinimum("0.49.1"))
        #expect(!ServerReleaseVersion.isBelowMinimum("0.50.0"))
        #expect(!ServerReleaseVersion.isBelowMinimum("0.51.0"))
        #expect(!ServerReleaseVersion.isBelowMinimum(nil))
        #expect(!ServerReleaseVersion.isBelowMinimum("not-a-version"))
    }

    @Test func comparesNumericComponents() {
        #expect(ServerReleaseVersion.isOlder("0.9.0", than: "0.50.0"))
        #expect(ServerReleaseVersion.isOlder("0.50.0", than: "1.0.0"))
        #expect(!ServerReleaseVersion.isOlder("0.50.0", than: "0.50.0"))
    }
}

@Suite("Server update presentation")
struct ServerUpdatePresentationTests {
    @Test func namesTheAvailableVersion() {
        #expect(
            ServerUpdatePresentation.availableTitle(latestVersion: "0.51.0")
                == "Update available: 0.51.0"
        )
    }

    @Test func confirmationNamesTheVersionAndWarnsAboutSessions() {
        #expect(
            ServerUpdatePresentation.confirmationTitle(version: "0.51.0") == "Update to 0.51.0?"
        )
        #expect(ServerUpdatePresentation.confirmationMessage.contains("interrupted"))
    }

    @Test func progressCopyFollowsInstallThenRestart() {
        #expect(
            ServerUpdatePresentation.progressLabel(status: "installing", restartMode: "reexec")
                == "Installing…"
        )
        #expect(
            ServerUpdatePresentation.progressLabel(status: "restarting", restartMode: "launchd")
                == "Restarting…"
        )
        #expect(
            ServerUpdatePresentation.progressLabel(status: "restarting", restartMode: "manual")
                .contains("Restart the Oppi server")
        )
    }
}
