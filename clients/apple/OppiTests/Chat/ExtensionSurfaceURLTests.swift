import Foundation
import Testing
@testable import Oppi

@Suite("Extension surface URL policy")
@MainActor
struct ExtensionSurfaceURLTests {
    private let workspaceID = "ws-1"
    private let serverID = "server-1"
    private let currentSessionId = "session-parent"
    private let hardcodedSessionHint = "Opens the related session"

    @Test func routesClassifiedDestinations() throws {
        for testCase in Self.routingCases {
            let url = try #require(testCase.url(), "URL for \(testCase.name)")
            let outcome = ExtensionSurfaceLinkRouting.outcome(
                for: url,
                serverID: serverID,
                workspaceID: workspaceID,
                currentSessionId: testCase.currentSessionId
            )
            testCase.expected.match(outcome, name: testCase.name)
        }
    }

    @Test func accessibilityHintIsNotHardcodedSessionSentenceForWebOrFile() throws {
        let destinations: [(String, String)] = [
            ("https://example.com/docs", currentSessionId),
            ("file:///tmp/report.md", currentSessionId),
        ]

        for (rawURL, sessionId) in destinations {
            let url = testUnwrap(URL(string: rawURL))
            let outcome = ExtensionSurfaceLinkRouting.outcome(
                for: url,
                serverID: serverID,
                workspaceID: workspaceID,
                currentSessionId: sessionId
            )
            let hint = ExtensionSurfaceLinkRouting.accessibilityHint(for: outcome)
            #expect(hint != hardcodedSessionHint, "hint for \(rawURL) should follow the classified destination")
            #expect(hint != nil)
        }
    }

    static let routingCases: [RoutingCase] = [
        RoutingCase(
            name: "child session pushes",
            rawURL: "oppi://session/child-1",
            currentSessionId: "session-parent",
            expected: .session(id: "child-1", workspaceID: "ws-1")
        ),
        RoutingCase(
            name: "same session is ignored",
            rawURL: "oppi://session/session-parent",
            currentSessionId: "session-parent",
            expected: .ignore
        ),
        RoutingCase(
            name: "https is a web link",
            rawURL: "https://example.com/docs",
            currentSessionId: "session-parent",
            expected: .webLink
        ),
        RoutingCase(
            name: "in-scope resource reference",
            rawURL: nil,
            currentSessionId: "session-parent",
            expected: .resourceReference
        ),
        RoutingCase(
            name: "scheme-less is unhandled",
            rawURL: "docs/foo.md",
            currentSessionId: "session-parent",
            expected: .unhandled
        ),
        RoutingCase(
            name: "unknown scheme is unhandled",
            rawURL: "ftp://example.com/file",
            currentSessionId: "session-parent",
            expected: .unhandled
        ),
    ]

    struct RoutingCase: Sendable {
        enum Expected: Sendable {
            case session(id: String, workspaceID: String?)
            case ignore
            case webLink
            case resourceReference
            case unhandled

            func match(_ outcome: ExtensionSurfaceLinkOutcome?, name: String) {
                switch (self, outcome) {
                case (.session(let expectedID, let workspaceID), .open(.session(let open))?):
                    #expect(open.sessionId == expectedID, "\(name)")
                    #expect(open.workspaceId == workspaceID, "\(name)")
                    #expect(open.origin == .inAppHyperlink, "\(name)")
                case (.ignore, .ignore?):
                    break
                case (.webLink, .open(.webLink)?):
                    break
                case (.resourceReference, .open(.resourceReference)?):
                    break
                case (.unhandled, nil):
                    break
                default:
                    Issue.record("\(name): expected \(self), got \(String(describing: outcome))")
                }
            }
        }

        let name: String
        let rawURL: String?
        let currentSessionId: String
        let expected: Expected

        func url() -> URL? {
            if let rawURL {
                return URL(string: rawURL)
            }
            return ResourceReferenceURL.make(
                ResourceReference(
                    target: "docs/foo.md",
                    sourceServerID: "server-1",
                    workspaceID: "ws-1",
                    sourceSessionID: "session-parent",
                    fileCandidatePath: "docs/foo.md",
                    kind: .workspaceFile
                )
            )
        }
    }
}
