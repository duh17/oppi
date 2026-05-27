import Foundation
import Testing
@testable import Oppi

@Suite("WorkspaceDeepLink")
struct WorkspaceDeepLinkTests {
    @Test func parsesWorkspaceHostURL() throws {
        let url = try #require(URL(string: "oppi://workspace?path=/Users/me/workspace/oppi&name=Oppi"))
        let payload = try #require(WorkspaceDeepLink.payload(from: url))

        #expect(payload.path == "/Users/me/workspace/oppi")
        #expect(payload.name == "Oppi")
        #expect(payload.serverFingerprint == nil)
    }

    @Test func parsesWorkspacePathOnlyURL() throws {
        let url = try #require(URL(string: "oppi:///workspace?path=/srv/repo&name=Server%20Repo"))
        let payload = try #require(WorkspaceDeepLink.payload(from: url))

        #expect(payload.path == "/srv/repo")
        #expect(payload.name == "Server Repo")
    }

    @Test func parsesServerFingerprintAndTrimsOptionalFields() throws {
        let url = try #require(URL(string: "oppi://workspace?path=%20/Users/me/project%20&name=%20Project%20&server=%20sha256:abc123%20"))
        let payload = try #require(WorkspaceDeepLink.payload(from: url))

        #expect(payload.path == "/Users/me/project")
        #expect(payload.name == "Project")
        #expect(payload.serverFingerprint == "sha256:abc123")
    }

    @Test func treatsEmptyNameAndServerAsNil() throws {
        let url = try #require(URL(string: "oppi://workspace?path=/tmp/project&name=%20%20&server=%20"))
        let payload = try #require(WorkspaceDeepLink.payload(from: url))

        #expect(payload.name == nil)
        #expect(payload.serverFingerprint == nil)
    }

    @Test func preservesLiteralPercentEscapesAfterURLComponentsDecoding() throws {
        let url = try #require(URL(string: "oppi://workspace?path=/tmp/a%252Fb&name=literal%252Fname"))
        let payload = try #require(WorkspaceDeepLink.payload(from: url))

        #expect(payload.path == "/tmp/a%2Fb")
        #expect(payload.name == "literal%2Fname")
    }

    @Test func rejectsUnsupportedURLs() throws {
        let invite = try #require(URL(string: "oppi://connect?v=3&invite=test"))
        let https = try #require(URL(string: "https://example.com/workspace?path=/tmp/project"))
        let missingPath = try #require(URL(string: "oppi://workspace?name=Project"))
        let emptyPath = try #require(URL(string: "oppi://workspace?path=%20%20&name=Project"))

        #expect(WorkspaceDeepLink.payload(from: invite) == nil)
        #expect(WorkspaceDeepLink.payload(from: https) == nil)
        #expect(WorkspaceDeepLink.payload(from: missingPath) == nil)
        #expect(WorkspaceDeepLink.payload(from: emptyPath) == nil)
    }

    @Test func matchesFingerprintsWithOrWithoutShaPrefix() {
        #expect(WorkspaceDeepLink.fingerprintsMatch("sha256:abc123", "abc123"))
        #expect(WorkspaceDeepLink.fingerprintsMatch("abc123", "sha256:abc123"))
        #expect(!WorkspaceDeepLink.fingerprintsMatch("abc123", "def456"))
    }
}
