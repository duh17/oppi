import Foundation
import Testing
@testable import Oppi

@Suite("PermissionDeepLink")
struct PermissionDeepLinkTests {
    @Test func parsesPermissionFromHostPath() throws {
        let url = try #require(URL(string: "oppi://permission/perm-123"))

        #expect(PermissionDeepLink.permissionID(from: url) == "perm-123")
    }

    @Test func parsesPermissionFromHostQuery() throws {
        let url = try #require(URL(string: "pi://permission?id=perm%2F123"))

        #expect(PermissionDeepLink.permissionID(from: url) == "perm/123")
    }

    @Test func parsesPermissionFromPathOnlyURL() throws {
        let url = try #require(URL(string: "oppi:///permission/perm%20456"))

        #expect(PermissionDeepLink.permissionID(from: url) == "perm 456")
    }

    @Test func returnsNilForNonPermissionURL() throws {
        let url = try #require(URL(string: "oppi://connect?v=3&invite=test-payload"))

        #expect(PermissionDeepLink.permissionID(from: url) == nil)
    }

    @Test func returnsNilWhenPermissionIDMissing() throws {
        let url = try #require(URL(string: "oppi://permission"))

        #expect(PermissionDeepLink.permissionID(from: url) == nil)
    }
}
