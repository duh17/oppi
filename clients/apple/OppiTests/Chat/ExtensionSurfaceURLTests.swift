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

    @Test func rewrittenWidgetMarkdownContainsWorkspaceFileResourceReference() throws {
        let rewritten = ExtensionNativeMarkdownSupport.rewrittenMarkdown(
            "See [[docs/foo.md|Foo]]",
            serverID: serverID,
            workspaceID: workspaceID,
            sessionID: currentSessionId,
            sourceDirectory: nil
        )

        let destination = try #require(firstLinkDestination(in: rewritten))
        let reference = try #require(ResourceReferenceURL.parse(destination))

        #expect(reference.kind == .workspaceFile)
        #expect(reference.fileCandidatePath == "docs/foo.md")
        #expect(reference.workspaceID == workspaceID)
        #expect(reference.target == "docs/foo.md")
    }

    @Test func routesClassifiedDestinations() throws {
        for testCase in Self.routingCases {
            let url = try #require(testCase.url(), "URL for \(testCase.name)")
            let action = ExtensionSurfaceLinkRouting.action(
                for: url,
                serverID: serverID,
                workspaceID: workspaceID,
                currentSessionId: testCase.currentSessionId
            )
            testCase.expected.match(action, name: testCase.name)
        }
    }

    @Test func accessibilityHintIsNotHardcodedSessionSentenceForWebOrFile() throws {
        let destinations: [(String, String)] = [
            ("https://example.com/docs", currentSessionId),
            ("file:///tmp/report.md", currentSessionId),
        ]

        for (rawURL, sessionId) in destinations {
            let url = try #require(URL(string: rawURL))
            let action = ExtensionSurfaceLinkRouting.action(
                for: url,
                serverID: serverID,
                workspaceID: workspaceID,
                currentSessionId: sessionId
            )
            let hint = ExtensionSurfaceLinkRouting.accessibilityHint(for: action)
            #expect(hint != hardcodedSessionHint, "hint for \(rawURL) should follow the classified destination")
            #expect(hint != nil)
        }
    }

    static let routingCases: [RoutingCase] = [
        RoutingCase(
            name: "child session pushes",
            rawURL: "oppi://session/child-1",
            currentSessionId: "session-parent",
            expected: .pushSession(id: "child-1")
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
            case pushSession(id: String)
            case ignore
            case webLink
            case resourceReference
            case unhandled

            func match(_ action: ExtensionSurfaceOpenAction, name: String) {
                switch (self, action) {
                case (.pushSession(let expectedID), .pushSession(let link)):
                    #expect(link.sessionId == expectedID, "\(name)")
                case (.ignore, .ignore):
                    break
                case (.webLink, .webLink):
                    break
                case (.resourceReference, .resourceReference):
                    break
                case (.unhandled, .unhandled):
                    break
                default:
                    Issue.record("\(name): expected \(self), got \(action)")
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

    private func firstLinkDestination(in markdown: String) -> URL? {
        func destinations(in inlines: [MarkdownInline]) -> [String] {
            inlines.flatMap { inline -> [String] in
                switch inline {
                case .link(_, let destination):
                    return destination.map { [$0] } ?? []
                case .emphasis(let children), .strong(let children), .strikethrough(let children):
                    return destinations(in: children)
                default:
                    return []
                }
            }
        }

        for block in parseCommonMark(markdown) {
            if case .paragraph(let inlines) = block {
                if let raw = destinations(in: inlines).first, let url = URL(string: raw) {
                    return url
                }
            }
        }
        return nil
    }
}
