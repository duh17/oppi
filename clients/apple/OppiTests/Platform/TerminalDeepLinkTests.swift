import Foundation
import Testing
@testable import Oppi

@Suite("Terminal deep link")
struct TerminalDeepLinkTests {
    private static let session = "session:01a18b8b-8553-7528-a80f-b22306f97869"
    private static let block = "block:01a1987c-6abd-76c6-9f91-ab50f8808d8c"

    private func link(_ string: String) -> Result<TerminalDeepLink, TerminalDeepLinkError>? {
        TerminalOpen(url: URL(string: string)!)?.link
    }

    @Test func parsesRexIdsWithColonsEncodedOrNot() {
        let expected = TerminalDeepLink(sessionID: Self.session, blockID: Self.block)
        let encoded = "oppi://terminal/rex?session=session%3A01a18b8b-8553-7528-a80f-b22306f97869&block=block%3A01a1987c-6abd-76c6-9f91-ab50f8808d8c"
        let plain = "oppi://terminal/rex?session=\(Self.session)&block=\(Self.block)"
        #expect(link(encoded) == .success(expected))
        #expect(link(plain) == .success(expected))
        #expect(link("oppi:///terminal/rex?session=\(Self.session)&block=\(Self.block)") == .success(expected))
    }

    @Test func requestsFromAppOpenRequestKeepTheSourceServer() {
        let url = URL(string: "oppi://terminal/rex?session=\(Self.session)&block=\(Self.block)")!
        guard case .terminal(let open) = AppOpenRequest(url: url, origin: .inAppHyperlink, sourceServerID: "srv") else {
            Issue.record("not a terminal request")
            return
        }
        #expect(open.sourceServerID == "srv")
    }

    @Test func rejectsMissingParamsExtrasAndOtherMultiplexers() {
        #expect(link("oppi://terminal/rex?block=\(Self.block)") == .failure(.missing("session")))
        #expect(link("oppi://terminal/rex?session=\(Self.session)&block=") == .failure(.missing("block")))
        // Nothing but the two ids: a link can never carry a command.
        #expect(link("oppi://terminal/rex?session=a&block=b&cmd=rm") == .failure(.unknownParameter("cmd")))
        #expect(link("oppi://terminal/herdr?session=a&block=b") == .failure(.unsupportedMultiplexer))
        #expect(link("oppi://terminal?session=a&block=b") == .failure(.unsupportedMultiplexer))
        #expect(link("oppi://workspace?path=/x") == nil)
        #expect(link("https://terminal/rex?session=a&block=b") == nil)
    }

    // MARK: Routing

    private let good = Result<TerminalDeepLink, TerminalDeepLinkError>.success(
        TerminalDeepLink(sessionID: "session:1", blockID: "block:1")
    )

    private func profile(_ host: String, rex: Bool) -> SSHTerminalProfile {
        SSHTerminalProfile(host: host, username: "alex", opensRexSessions: rex)
    }

    private func decide(
        _ link: Result<TerminalDeepLink, TerminalDeepLinkError>? = nil,
        host: String? = "mac-studio.tail1234.ts.net",
        profiles: [SSHTerminalProfile],
        rex: Bool = true
    ) -> TerminalLinkRoute {
        TerminalLinkRoute.decide(link: link ?? good, serverHost: host, profiles: profiles, rexEnabled: rex)
    }

    @Test func opensOnTheSavedRexHostForTheServer() {
        let plain = profile("mac-studio", rex: false)
        let rex = profile("Mac-Studio.tail1234.ts.net", rex: true)
        #expect(decide(profiles: [plain, rex]) == .openPane(rex, TerminalDeepLink(sessionID: "session:1", blockID: "block:1")))
    }

    @Test func anUnknownHostOffersAddHostWithTheServersHost() {
        #expect(decide(profiles: [profile("mac-mini", rex: true)]) == .addHost(serverHost: "mac-studio.tail1234.ts.net"))
        #expect(decide(profiles: []) == .addHost(serverHost: "mac-studio.tail1234.ts.net"))
    }

    @Test func plainErrorsNeverGuessAHost() {
        let notRex = profile("mac-studio", rex: false)
        #expect(decide(profiles: [notRex]) == .hostNotRex(notRex))
        #expect(decide(profiles: [notRex], rex: false) == .rexOff)
        #expect(decide(host: nil, profiles: [notRex]) == .noServerHost)
        #expect(decide(.failure(.missing("block")), profiles: [notRex]) == .invalid(.missing("block")))
    }
}
