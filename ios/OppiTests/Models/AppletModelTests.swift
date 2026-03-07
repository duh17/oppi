import Foundation
import Testing
@testable import Oppi

@Suite("Applet Models")
struct AppletModelTests {
    @Test func appletDecodesUnixMilliseconds() throws {
        let json = """
        {
          "id": "applet-1",
          "workspaceId": "w1",
          "title": "JSON Viewer",
          "description": "Inspect JSON",
          "currentVersion": 3,
          "tags": ["json", "tool"],
          "createdAt": 1700000000000,
          "updatedAt": 1700000300000
        }
        """

        let applet = try JSONDecoder().decode(Applet.self, from: Data(json.utf8))

        #expect(applet.id == "applet-1")
        #expect(applet.workspaceId == "w1")
        #expect(applet.currentVersion == 3)
        #expect(applet.tags == ["json", "tool"])
        #expect(applet.createdAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(applet.updatedAt == Date(timeIntervalSince1970: 1_700_000_300))
    }

    @Test func appletVersionDecodesOptionalProvenance() throws {
        let json = """
        {
          "version": 2,
          "appletId": "applet-1",
          "sessionId": "session-abc",
          "toolCallId": "tool-123",
          "size": 2048,
          "changeNote": "Added filters",
          "createdAt": 1700000400000
        }
        """

        let version = try JSONDecoder().decode(AppletVersion.self, from: Data(json.utf8))

        #expect(version.version == 2)
        #expect(version.appletId == "applet-1")
        #expect(version.sessionId == "session-abc")
        #expect(version.toolCallId == "tool-123")
        #expect(version.size == 2048)
        #expect(version.changeNote == "Added filters")
        #expect(version.createdAt == Date(timeIntervalSince1970: 1_700_000_400))
    }

    @Test func appletVersionWithHTMLDecodesEmbeddedVersionAndHTML() throws {
        let json = """
        {
          "version": 4,
          "appletId": "applet-7",
          "sessionId": "session-z",
          "toolCallId": "call-z",
          "size": 1234,
          "changeNote": "Polish",
          "createdAt": 1700000500000,
          "html": "<!doctype html><html><body>Hello</body></html>"
        }
        """

        let payload = try JSONDecoder().decode(AppletVersionWithHTML.self, from: Data(json.utf8))

        #expect(payload.version.version == 4)
        #expect(payload.version.appletId == "applet-7")
        #expect(payload.version.sessionId == "session-z")
        #expect(payload.version.toolCallId == "call-z")
        #expect(payload.version.changeNote == "Polish")
        #expect(payload.html.contains("<body>Hello</body>"))
    }
}
