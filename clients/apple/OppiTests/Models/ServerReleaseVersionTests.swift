import Foundation
import Testing
@testable import Oppi

@Suite("Server release version")
struct ServerReleaseVersionTests {
    @Test func minimumSupportedIs0510() {
        #expect(ServerReleaseVersion.minimumSupported == "0.51.0")
    }

    @Test func treatsOlderServersAsBelowMinimum() {
        #expect(ServerReleaseVersion.isBelowMinimum("0.49.1"))
        #expect(ServerReleaseVersion.isBelowMinimum("0.50.0"))
        #expect(!ServerReleaseVersion.isBelowMinimum("0.51.0"))
        #expect(!ServerReleaseVersion.isBelowMinimum("0.52.0"))
        #expect(!ServerReleaseVersion.isBelowMinimum(nil))
        #expect(!ServerReleaseVersion.isBelowMinimum("not-a-version"))
    }

    @Test func comparesNumericComponents() {
        #expect(ServerReleaseVersion.isOlder("0.9.0", than: "0.50.0"))
        #expect(ServerReleaseVersion.isOlder("0.50.0", than: "1.0.0"))
        #expect(!ServerReleaseVersion.isOlder("0.50.0", than: "0.50.0"))
    }
}
