import Foundation
import Testing
@testable import Oppi

@Suite("Server release version")
struct ServerReleaseVersionTests {
    @Test func treatsOlderServersAsBelowMinimum() {
        #expect(ServerReleaseVersion.isBelowMinimum("0.49.1"))
        #expect(ServerReleaseVersion.isBelowMinimum("0.51.0"))
        #expect(!ServerReleaseVersion.isBelowMinimum("0.52.0"))
        #expect(!ServerReleaseVersion.isBelowMinimum("0.53.0"))
        #expect(!ServerReleaseVersion.isBelowMinimum(nil))
        #expect(!ServerReleaseVersion.isBelowMinimum("not-a-version"))
    }

    @Test func comparesNumericComponents() {
        #expect(ServerReleaseVersion.isOlder("0.9.0", than: "0.50.0"))
        #expect(ServerReleaseVersion.isOlder("0.50.0", than: "1.0.0"))
        #expect(!ServerReleaseVersion.isOlder("0.50.0", than: "0.50.0"))
    }

    /// The below-minimum notice explains itself only while npm cannot satisfy the floor.
    @Test func explainsMinimumOnlyWhileNpmLacksAQualifyingVersion() {
        let detail = ServerUpdatePresentation.minimumVersionUnpublishedDetail
        #expect(detail("0.51.0", false, "0.52.0") != nil)
        #expect(detail(nil, false, "0.52.0") != nil)
        #expect(detail("0.52.0", false, "0.52.0") == nil)
        #expect(detail("0.53.0", false, "0.52.0") == nil)
        // A linked checkout at the floor clears it by rebuilding.
        #expect(detail("0.52.0", true, "0.52.0") == nil)
        #expect(detail("0.51.0", true, "0.52.0") != nil)
    }
}
