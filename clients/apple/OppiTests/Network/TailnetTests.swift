import Foundation
import Network
import Testing
@testable import Oppi

// MARK: - Node state

@Suite("Tailnet node state")
struct TailnetNodeStatusTests {
    private let loginURL = URL(string: "https://login.tailscale.com/a/1a2b3c4d")

    @Test func needsLoginWaitsForControlURLThenOffersIt() {
        var status = TailnetNodeStatus()
        #expect(status.nodeState == .starting)

        status.apply(TailnetBusEvent(state: .needsLogin))
        #expect(status.nodeState == .needsLogin(nil))

        status.apply(TailnetBusEvent(browseToURL: "https://login.tailscale.com/a/1a2b3c4d"))
        #expect(status.nodeState == .needsLogin(loginURL))
        #expect(status.isRunning == false)
    }

    @Test func browseToURLBeforeNeedsLoginStillPromptsLogin() {
        var status = TailnetNodeStatus()
        status.apply(TailnetBusEvent(state: .starting, browseToURL: "https://login.tailscale.com/a/1a2b3c4d"))
        #expect(status.nodeState == .needsLogin(loginURL))
    }

    @Test func nonHTTPSLoginURLIsNeverOffered() {
        var status = TailnetNodeStatus()
        status.apply(TailnetBusEvent(state: .needsLogin, browseToURL: "javascript:alert(1)"))
        status.apply(TailnetBusEvent(browseToURL: "http://login.tailscale.com/a/plain"))
        #expect(status.nodeState == .needsLogin(nil))
    }

    @Test func runningClearsLoginAndALaterLogoutNeedsAFreshURL() {
        var status = TailnetNodeStatus()
        status.apply(TailnetBusEvent(state: .needsLogin, browseToURL: "https://login.tailscale.com/a/1a2b3c4d"))

        status.apply(TailnetBusEvent(loginFinished: true))
        status.apply(TailnetBusEvent(state: .running))
        #expect(status.nodeState == .running)
        #expect(status.isRunning)

        // Key expiry or logout: the consumed URL must not be reopened.
        status.apply(TailnetBusEvent(state: .needsLogin))
        #expect(status.nodeState == .needsLogin(nil))
    }

    @Test func machineAuthIsDistinctFromLogin() {
        var status = TailnetNodeStatus()
        status.apply(TailnetBusEvent(state: .needsMachineAuth))
        #expect(status.nodeState == .needsMachineAuth)
    }

    @Test func backendErrorFailsStartupUntilRunning() {
        var status = TailnetNodeStatus()
        status.apply(TailnetBusEvent(state: .starting, errorMessage: "control: dial failed"))
        #expect(status.nodeState == .failed("control: dial failed"))

        status.apply(TailnetBusEvent(state: .running))
        #expect(status.nodeState == .running)
    }

    @Test func statusSnapshotSuppliesMissedAuthURL() throws {
        var status = TailnetNodeStatus()
        let snapshot = try TailnetStatusProjection.snapshot(fromStatusJSON: Data(TailnetFixtures.needsLoginStatus.utf8))
        status.apply(snapshot)
        #expect(status.nodeState == .needsLogin(URL(string: "https://login.tailscale.com/a/5e6f7a8b")))
        #expect(snapshot.peers.isEmpty)
    }

    @Test func statusSnapshotRunningMarksNodeUp() throws {
        var status = TailnetNodeStatus()
        status.apply(TailnetBusEvent(state: .needsLogin, browseToURL: "https://login.tailscale.com/a/1a2b3c4d"))
        status.apply(try TailnetStatusProjection.snapshot(fromStatusJSON: Data(TailnetFixtures.runningStatus.utf8)))
        #expect(status.nodeState == .running)
    }
}

// MARK: - Launch start

@Suite("Tailnet launch start")
struct TailnetLaunchStartTests {
    @Test func skippedWhenEnabledWithoutTailnetServer() {
        #expect(!TailnetNodeController.shouldStartAtLaunch(
            isEnabled: true,
            pairedHosts: ["192.168.1.10", "oppi.example.com", "localhost"]
        ))
    }

    @Test func notSkippedWhenEnabledWithTailnetServer() {
        #expect(TailnetNodeController.shouldStartAtLaunch(
            isEnabled: true,
            pairedHosts: ["192.168.1.10", "studio.tail1234.ts.net"]
        ))
        #expect(TailnetNodeController.shouldStartAtLaunch(
            isEnabled: true,
            pairedHosts: ["mac.beta.tailscale.net"]
        ))
        #expect(!TailnetNodeController.shouldStartAtLaunch(
            isEnabled: false,
            pairedHosts: ["studio.tail1234.ts.net"]
        ))
    }
}

// MARK: - LocalAPI peer projection

@Suite("Tailnet LocalAPI peer projection")
struct TailnetStatusProjectionTests {
    @Test func runningStatusProjectsOnlineMachines() throws {
        let snapshot = try TailnetStatusProjection.snapshot(fromStatusJSON: Data(TailnetFixtures.runningStatus.utf8))

        #expect(snapshot.backendState == .running)
        #expect(snapshot.selfDNSName == "oppi-ios.tail1234.ts.net")
        #expect(snapshot.tailnetName == "chen@example.com")
        #expect(snapshot.peers.map(\.displayName) == ["build-box", "mac-studio", "old-laptop"])

        let online = snapshot.onlinePeers
        #expect(online.map(\.displayName) == ["build-box", "mac-studio"])
        let studio = try #require(online.last)
        #expect(studio.id == "nStudio1CNTRL")
        #expect(studio.hostName == "Mac Studio")
        #expect(studio.dnsName == "mac-studio.tail1234.ts.net")
        #expect(studio.os == "macOS")
        #expect(studio.tailscaleIPs == ["100.101.102.103", "fd7a:115c:a1e0::1"])
    }

    @Test func peerWithoutMagicDNSNameFallsBackToHostName() throws {
        let json = """
        {"BackendState":"Running","Peer":{"nodekey:aa":{"ID":"n1","HostName":"printer","DNSName":"","Online":true,"TailscaleIPs":["100.64.0.9"]}}}
        """
        let peer = try #require(TailnetStatusProjection.snapshot(fromStatusJSON: Data(json.utf8)).onlinePeers.first)
        #expect(peer.displayName == "printer")
        #expect(peer.dnsName.isEmpty)
        #expect(peer.tailscaleIPs == ["100.64.0.9"])
    }

    @Test func missingPeerMapIsAnEmptyMachineList() throws {
        let snapshot = try TailnetStatusProjection.snapshot(fromStatusJSON: Data(#"{"BackendState":"Starting"}"#.utf8))
        #expect(snapshot.backendState == .starting)
        #expect(snapshot.peers.isEmpty)
        #expect(snapshot.authURL == nil)
    }

    @Test func unknownBackendStateIsRejected() {
        #expect(throws: TailnetStatusProjectionError.unknownBackendState("Hibernating")) {
            try TailnetStatusProjection.snapshot(fromStatusJSON: Data(#"{"BackendState":"Hibernating"}"#.utf8))
        }
    }
}

// MARK: - Same-user pairing probe

@MainActor
@Suite("Tailnet same-user pairing")
struct TailnetSameUserPairingTests {
    @Test func proxyWaitExpiresAtBoundedVirtualDeadline() async {
        var now = ContinuousClock.now
        var polls = 0
        await #expect(throws: TailnetSameUserPairing.Failure.proxyNotReady) {
            try await TailnetSameUserPairing.waitForCurrentGenerationProxy(
                expectedGeneration: 7,
                timeout: .seconds(6),
                generation: { 7 },
                nodeState: { .running },
                proxy: { nil },
                now: { now },
                sleep: { _ in polls += 1; now += .seconds(2) }
            )
        }
        #expect(polls == 3)
    }

    @Test func proxyWaitAcceptsPublicationFromCurrentGeneration() async throws {
        var proxy: TailnetSOCKSProxy?
        var polls = 0
        try await TailnetSameUserPairing.waitForCurrentGenerationProxy(
            expectedGeneration: 7,
            generation: { 7 },
            nodeState: { .running },
            proxy: { proxy },
            sleep: { _ in
                polls += 1
                proxy = TailnetSOCKSProxy(host: "127.0.0.1", port: 1080, credential: "fixture")
            }
        )
        #expect(polls == 1)
    }

    @Test func probeOrderIsConfigDefaultThenHTTPS() throws {
        let urls = TailnetSameUserPairing.probeURLs(dnsName: "mac-studio.tail1234.ts.net")
        #expect(urls.map(\.absoluteString) == [
            "https://mac-studio.tail1234.ts.net:7749",
            "https://mac-studio.tail1234.ts.net:443",
        ])
        #expect(TailnetSameUserPairing.probePorts == [7749, 443])
    }

    @Test func firstHealthyProbeTriesDefaultPortBefore443() async throws {
        var seen: [String] = []
        let url = try await TailnetSameUserPairing.firstHealthyProbeURL(
            dnsName: "mac-studio.tail1234.ts.net"
        ) { candidate in
            seen.append(candidate.absoluteString)
            return candidate.absoluteString.hasSuffix(":443")
        }
        #expect(seen == [
            "https://mac-studio.tail1234.ts.net:7749",
            "https://mac-studio.tail1234.ts.net:443",
        ])
        #expect(url.absoluteString == "https://mac-studio.tail1234.ts.net:443")
    }

    @Test func firstHealthyProbeStopsAtDefaultPort() async throws {
        var seen: [String] = []
        let url = try await TailnetSameUserPairing.firstHealthyProbeURL(
            dnsName: "mac-studio.tail1234.ts.net"
        ) { candidate in
            seen.append(candidate.absoluteString)
            return true
        }
        #expect(seen == ["https://mac-studio.tail1234.ts.net:7749"])
        #expect(url.absoluteString == "https://mac-studio.tail1234.ts.net:7749")
    }

    @Test func doesNotBuildAPIClientUntilNodeIsRunning() throws {
        let url = testUnwrap(URL(string: "https://mac-studio.tail1234.ts.net:7749"))
        let proxy = TailnetSOCKSProxy(host: "127.0.0.1", port: 1080, credential: "cred")
        let blocked: [TailnetNodeState] = [
            .off,
            .starting,
            .needsLogin(nil),
            .needsMachineAuth,
            .failed("down"),
        ]
        for state in blocked {
            var built = 0
            #expect(throws: TailnetSameUserPairing.Failure.nodeNotRunning) {
                try TailnetSameUserPairing.makeBootstrapClient(
                    nodeState: state,
                    proxy: proxy,
                    baseURL: url,
                    makeClient: { _ in
                        built += 1
                        return "client"
                    }
                )
            }
            #expect(built == 0)
        }
    }

    @Test func doesNotBuildAPIClientWhenRunningBeforeProxyPublication() throws {
        let url = testUnwrap(URL(string: "https://mac-studio.tail1234.ts.net:7749"))
        var built = 0
        #expect(throws: TailnetSameUserPairing.Failure.proxyNotReady) {
            try TailnetSameUserPairing.makeBootstrapClient(
                nodeState: .running,
                proxy: nil,
                baseURL: url,
                makeClient: { _ in
                    built += 1
                    return "client"
                }
            )
        }
        #expect(built == 0)
    }

    @Test func buildsAPIClientOnceTheNodeIsConnectedAndProxyIsPublished() throws {
        var built = 0
        let client = try TailnetSameUserPairing.makeBootstrapClient(
            nodeState: .running,
            proxy: TailnetSOCKSProxy(host: "127.0.0.1", port: 1080, credential: "cred"),
            baseURL: testUnwrap(URL(string: "https://mac-studio.tail1234.ts.net:7749")),
            makeClient: { url in
                built += 1
                return url
            }
        )
        #expect(built == 1)
        #expect(client.host == "mac-studio.tail1234.ts.net")
    }

    @Test func waitsForDelayedProxyPublicationNotJustRunning() async throws {
        final class Hold {
            var proxy: TailnetSOCKSProxy?
            var observedNilWhileRunning = false
        }
        let hold = Hold()
        let waiter = Task { @MainActor in
            try await TailnetSameUserPairing.waitForCurrentGenerationProxy(
                expectedGeneration: 9,
                timeout: .seconds(2),
                generation: { 9 },
                nodeState: { .running },
                proxy: {
                    if hold.proxy == nil { hold.observedNilWhileRunning = true }
                    return hold.proxy
                }
            )
        }
        let seenDeadline = ContinuousClock.now + .seconds(1)
        while !hold.observedNilWhileRunning {
            if ContinuousClock.now >= seenDeadline { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(hold.observedNilWhileRunning)
        hold.proxy = TailnetSOCKSProxy(host: "127.0.0.1", port: 1080, credential: "cred")
        try await waiter.value
    }

    @Test func runningWithoutProxyTimesOutInsteadOfTreatingEnumAsReady() async throws {
        await #expect(throws: TailnetSameUserPairing.Failure.proxyNotReady) {
            try await TailnetSameUserPairing.waitForCurrentGenerationProxy(
                expectedGeneration: 1,
                timeout: .milliseconds(80),
                generation: { 1 },
                nodeState: { .running },
                proxy: { nil }
            )
        }
    }

    @Test func generationChangeFailsProxyWaitClosed() async throws {
        await #expect(throws: TailnetSameUserPairing.Failure.nodeNotRunning) {
            try await TailnetSameUserPairing.waitForCurrentGenerationProxy(
                expectedGeneration: 4,
                timeout: .seconds(1),
                generation: { 5 },
                nodeState: { .running },
                proxy: { TailnetSOCKSProxy(host: "127.0.0.1", port: 1080, credential: "cred") }
            )
        }
    }
}

// MARK: - Machine list status

@Suite("Tailnet machine list status")
@MainActor
struct TailnetPeerStatusTests {
    private static func peer(_ name: String, dns: String? = nil, os: String? = "macOS") -> TailnetPeer {
        TailnetPeer(
            id: "n-\(name)",
            hostName: name,
            dnsName: dns ?? "\(name).tail1234.ts.net",
            os: os,
            tailscaleIPs: ["100.64.0.1"],
            isOnline: true
        )
    }

    private static let probeFailure = URLError(.cannotConnectToHost)
    private static let certificateFailure = URLError(.serverCertificateUntrusted)

    @Test(arguments: ["iOS", "iPadOS", "android", "Android"])
    func phonesAndTabletsCannotHostOppi(os: String) {
        #expect(!Self.peer("iphone171", os: os).canHostOppi)
    }

    @Test(arguments: ["macOS", "linux", "windows", nil])
    func everyOtherMachineMayHostOppi(os: String?) {
        #expect(Self.peer("box", os: os).canHostOppi)
    }

    @Test func setupCheckNamesTheHostOS() {
        #expect(Self.peer("studio", os: "macOS").setupCheckTitle == "Check this Mac")
        #expect(Self.peer("box", os: "linux").setupCheckTitle == "Check this Linux machine")
        #expect(Self.peer("box", os: "Linux").setupCheckTitle == "Check this Linux machine")
        #expect(Self.peer("pc", os: "windows").setupCheckTitle == "Check this machine")
        #expect(Self.peer("mystery", os: nil).setupCheckTitle == "Check this machine")
    }

    @Test func preferredSetupPeerSkipsPhonesAndPrefersMacThenLinux() {
        let phone = Self.peer("iphone", os: "iOS")
        let linux = Self.peer("build-box", os: "linux")
        let mac = Self.peer("mac-studio", os: "macOS")
        #expect(TailnetPeer.preferredSetupPeer(among: [phone, linux, mac])?.hostName == "mac-studio")
        #expect(TailnetPeer.preferredSetupPeer(among: [phone, linux])?.hostName == "build-box")
        #expect(TailnetPeer.preferredSetupPeer(among: [phone]) == nil)
    }

    @Test func pairedHostMatchIgnoresCaseAndRootDot() {
        let studio = Self.peer("mac-studio")
        #expect(TailnetPeerStatus.derive(
            peer: studio, pairedHosts: ["Mac-Studio.TAIL1234.ts.net."], probe: nil
        ) == .paired)
        #expect(TailnetPeerStatus.derive(
            peer: studio, pairedHosts: ["mac-mini.tail1234.ts.net", "192.168.1.5"], probe: nil
        ) == .unchecked)
    }

    @Test func pairedWinsOverAnyProbeResult() {
        let studio = Self.peer("mac-studio")
        for probe: TailnetPeerProbe? in [nil, .inFlight, .ready, .needsCertificate, .notReachable] {
            #expect(TailnetPeerStatus.derive(
                peer: studio, pairedHosts: [studio.dnsName], probe: probe
            ) == .paired)
        }
    }

    @Test func peerWithoutMagicDNSNameNeverMatchesAPairedHost() {
        let printer = Self.peer("printer", dns: "")
        #expect(TailnetPeerStatus.derive(peer: printer, pairedHosts: [""], probe: .ready) == .ready)
    }

    @Test func probeOutcomeSelectsTheRowState() {
        let studio = Self.peer("mac-studio")
        let expected: [(TailnetPeerProbe?, TailnetPeerStatus)] = [
            (nil, .unchecked), (.inFlight, .checking), (.ready, .ready),
            (.needsCertificate, .needsCertificate), (.notReachable, .notReachable),
        ]
        for (probe, status) in expected {
            #expect(TailnetPeerStatus.derive(peer: studio, pairedHosts: [], probe: probe) == status)
        }
    }

    @Test func healthyPeerIsReadyOnTheFirstPortThatAnswers() async {
        var seen: [String] = []
        let outcome = await TailnetSameUserPairing.probeOutcome(dnsName: "mac-studio.tail1234.ts.net") { url in
            seen.append(url.absoluteString)
            return url.port == 443
        }
        #expect(outcome == .ready)
        #expect(seen.count == 2)
    }

    @Test func refusedOnEveryPortIsNotReachable() async {
        let outcome = await TailnetSameUserPairing.probeOutcome(dnsName: "macbook-pro.tail1234.ts.net") { _ in
            throw Self.probeFailure
        }
        #expect(outcome == .notReachable)
    }

    @Test func nonOppiAnswerIsNotReachable() async {
        let outcome = await TailnetSameUserPairing.probeOutcome(dnsName: "nas.tail1234.ts.net") { _ in false }
        #expect(outcome == .notReachable)
    }

    @Test func certificateRejectionOnTheDefaultPortSurvivesALaterRefusal() async {
        let outcome = await TailnetSameUserPairing.probeOutcome(dnsName: "mac-mini.tail1234.ts.net") { url in
            throw url.port == 7749 ? Self.certificateFailure : Self.probeFailure
        }
        #expect(outcome == .needsCertificate)
    }

    @Test func failedHandshakeWithoutACertificateVerdictIsNotReachable() async {
        // CFNetwork also reports a reset or SOCKS failure as secureConnectionFailed.
        let outcome = await TailnetSameUserPairing.probeOutcome(dnsName: "macbook-pro.tail1234.ts.net") { _ in
            throw URLError(.secureConnectionFailed)
        }
        #expect(outcome == .notReachable)
    }

    @Test func healthyPortBeatsAnEarlierCertificateRejection() async {
        let outcome = await TailnetSameUserPairing.probeOutcome(dnsName: "mac-mini.tail1234.ts.net") { url in
            if url.port == 7749 { throw Self.certificateFailure }
            return true
        }
        #expect(outcome == .ready)
    }

    @Test func machineWithoutMagicDNSNameCannotBeProbed() async {
        let outcome = await TailnetSameUserPairing.probeOutcome(dnsName: "") { _ in
            Issue.record("probe must not run without a host")
            return true
        }
        #expect(outcome == .notReachable)
    }

    @Test(arguments: [
        (#"{"ok":true,"protocol":2}"#, true),
        ("<html>Another service</html>", false),
        (#"{"ok":true}"#, false),
        (#"{"ok":true,"protocol":1}"#, false),
        (#"{"ok":false,"protocol":2}"#, false),
    ])
    func readinessRequiresOppiHealthIdentity(body: String, isOppi: Bool) async throws {
        let server = try await PeerHealthHTTPFixture.start(body: body)
        defer { server.stop() }
        let url = try #require(server.baseURL)
        let outcome = await TailnetSameUserPairing.probeOutcome(dnsName: "mac-studio.tail1234.ts.net") { _ in
            try await TailnetSameUserPairing.peerHealth(at: url)
        }
        #expect(outcome == (isOppi ? .ready : .notReachable))

        let afterCertificateFailure = await TailnetSameUserPairing.probeOutcome(dnsName: "mac-studio.tail1234.ts.net") { probeURL in
            if probeURL.port == 7749 { throw Self.certificateFailure }
            return try await TailnetSameUserPairing.peerHealth(at: url)
        }
        #expect(afterCertificateFailure == (isOppi ? .ready : .needsCertificate))
    }

    @Test func readinessNeverFollowsAHealthRedirect() async throws {
        let server = try await PeerHealthHTTPFixture.start(body: #"{"ok":true,"protocol":2}"#, redirects: true)
        defer { server.stop() }
        let url = try #require(server.baseURL)
        let outcome = await TailnetSameUserPairing.probeOutcome(dnsName: "mac-studio.tail1234.ts.net") { _ in
            try await TailnetSameUserPairing.peerHealth(at: url)
        }
        #expect(outcome == .notReachable)

        let afterCertificateFailure = await TailnetSameUserPairing.probeOutcome(dnsName: "mac-studio.tail1234.ts.net") { probeURL in
            if probeURL.port == 7749 { throw Self.certificateFailure }
            return try await TailnetSameUserPairing.peerHealth(at: url)
        }
        #expect(afterCertificateFailure == .needsCertificate)
        // The redirect destination returns genuine Oppi JSON. Reaching it
        // would both change readiness and escape the original peer's identity.
        #expect(server.paths == ["/health", "/health", "/health"])
    }

    @Test func onlyCertificateVerdictsCountAsCertificateFailure() {
        let certificate: [URLError.Code] = [
            .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
            .serverCertificateHasBadDate, .serverCertificateNotYetValid,
        ]
        let other: [URLError.Code] = [
            .secureConnectionFailed, .timedOut, .cannotConnectToHost, .networkConnectionLost, .cancelled,
        ]
        for code in certificate { #expect(TailnetSameUserPairing.isCertificateFailure(URLError(code))) }
        for code in other { #expect(!TailnetSameUserPairing.isCertificateFailure(URLError(code))) }
        #expect(!TailnetSameUserPairing.isCertificateFailure(CancellationError()))
    }
}

// MARK: - Transport through the node's SOCKS5 proxy

@Suite("Tailnet transport route", .serialized)
struct TailnetTransportRouteTests {
    @Test func tailnetHTTPSGoesThroughNodeSOCKSWithNodeCredential() async throws {
        let recorder = try await SOCKS5Recorder.start()
        defer { recorder.stop() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        TailnetTransportRoute.apply(
            to: configuration,
            proxy: TailnetSOCKSProxy(host: "127.0.0.1", port: recorder.port, credential: "node-proxy-credential")
        )
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let url = testUnwrap(URL(string: "https://oppi-server.tail1234.ts.net/server/info"))
        let request = Task { _ = try? await session.data(from: url) }
        defer { request.cancel() }

        let connection = try await recorder.nextConnection()
        #expect(connection == .socks(
            username: "tsnet",
            password: "node-proxy-credential",
            host: "oppi-server.tail1234.ts.net",
            port: 443
        ))
    }

    @Test func nonTailnetHostBypassesNodeProxy() async throws {
        let recorder = try await SOCKS5Recorder.start()
        defer { recorder.stop() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        TailnetTransportRoute.apply(
            to: configuration,
            proxy: TailnetSOCKSProxy(host: "127.0.0.1", port: recorder.port, credential: "node-proxy-credential")
        )
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        // A public name must resolve and connect directly; `.test` never
        // resolves, so the request fails without ever reaching the proxy.
        let url = testUnwrap(URL(string: "https://oppi.example.test/server/info"))
        let failed = await Task { () -> Bool in
            do {
                _ = try await session.data(from: url)
                return false
            } catch {
                return true
            }
        }.value
        #expect(failed)
        await #expect(throws: SOCKS5Recorder.RecorderError.timedOut) {
            try await recorder.nextConnection(timeout: .milliseconds(500))
        }
    }
}

// MARK: - Fixtures

private enum TailnetFixtures {
    /// Trimmed `tailscale status --json` / LocalAPI `/localapi/v0/status`.
    static let runningStatus = """
    {
      "Version": "1.94.1-t1234abcd",
      "TUN": false,
      "BackendState": "Running",
      "HaveNodeKey": true,
      "AuthURL": "",
      "TailscaleIPs": ["100.90.1.2", "fd7a:115c:a1e0::2"],
      "Self": {
        "ID": "nSelf1CNTRL",
        "PublicKey": "nodekey:self",
        "HostName": "oppi-ios",
        "DNSName": "oppi-ios.tail1234.ts.net.",
        "OS": "iOS",
        "TailscaleIPs": ["100.90.1.2"],
        "Online": true,
        "ExitNode": false,
        "ExitNodeOption": false
      },
      "Health": [],
      "MagicDNSSuffix": "tail1234.ts.net",
      "CurrentTailnet": {"Name": "chen@example.com", "MagicDNSSuffix": "tail1234.ts.net", "MagicDNSEnabled": true},
      "CertDomains": ["oppi-ios.tail1234.ts.net"],
      "Peer": {
        "nodekey:studio": {
          "ID": "nStudio1CNTRL",
          "PublicKey": "nodekey:studio",
          "HostName": "Mac Studio",
          "DNSName": "mac-studio.tail1234.ts.net.",
          "OS": "macOS",
          "UserID": 123,
          "TailscaleIPs": ["100.101.102.103", "fd7a:115c:a1e0::1"],
          "Online": true,
          "Active": true,
          "ExitNode": false,
          "ExitNodeOption": false,
          "LastSeen": "0001-01-01T00:00:00Z",
          "PeerAPIURL": ["http://100.101.102.103:12345"]
        },
        "nodekey:laptop": {
          "ID": "nLaptop1CNTRL",
          "HostName": "old-laptop",
          "DNSName": "old-laptop.tail1234.ts.net.",
          "OS": "linux",
          "TailscaleIPs": ["100.64.0.20"],
          "Online": false,
          "ExitNode": false,
          "ExitNodeOption": false,
          "LastSeen": "2026-06-01T10:00:00Z"
        },
        "nodekey:build": {
          "ID": "nBuild1CNTRL",
          "HostName": "ubuntu",
          "DNSName": "build-box.tail1234.ts.net.",
          "OS": "linux",
          "TailscaleIPs": ["100.64.0.30"],
          "Online": true,
          "ExitNode": false,
          "ExitNodeOption": true
        }
      },
      "User": {"123": {"ID": 123, "LoginName": "chen@example.com", "DisplayName": "Chen"}},
      "ClientVersion": null
    }
    """

    static let needsLoginStatus = """
    {
      "Version": "1.94.1-t1234abcd",
      "BackendState": "NeedsLogin",
      "HaveNodeKey": true,
      "AuthURL": "https://login.tailscale.com/a/5e6f7a8b",
      "TailscaleIPs": null,
      "Self": {"ID": "", "HostName": "oppi-ios", "DNSName": "", "Online": false, "ExitNode": false, "ExitNodeOption": false},
      "Health": ["not logged in"],
      "CurrentTailnet": null,
      "Peer": null
    }
    """
}

/// Real loopback HTTP responses exercise URLSession body parsing and redirect
/// policy without replacing that client boundary. TLS remains system-trusted
/// in production; the fixture uses HTTP under NSAllowsLocalNetworking.
private final class PeerHealthHTTPFixture: @unchecked Sendable {
    private let listener: NWListener
    private let body: String
    private let redirects: Bool
    private let lock = NSLock()
    private var requestedPaths: [String] = []

    private init(listener: NWListener, body: String, redirects: Bool) {
        self.listener = listener
        self.body = body
        self.redirects = redirects
    }

    var baseURL: URL? {
        listener.port.flatMap { URL(string: "http://127.0.0.1:\($0.rawValue)") }
    }

    var paths: [String] { lock.withLock { requestedPaths } }

    static func start(body: String, redirects: Bool = false) async throws -> PeerHealthHTTPFixture {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let server = PeerHealthHTTPFixture(listener: listener, body: body, redirects: redirects)
        let queue = DispatchQueue(label: "oppi.tests.peer-health")
        listener.newConnectionHandler = { [weak server] connection in
            connection.start(queue: queue)
            server?.receive(connection)
        }
        try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, Error>) in
            let resumed = LockedFlag()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.setOnce() { ready.resume() }
                case .failed(let error):
                    if resumed.setOnce() { ready.resume(throwing: error) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
        return server
    }

    func stop() { listener.cancel() }

    private func receive(_ connection: NWConnection, accumulated: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [self] data, _, complete, error in
            var request = accumulated
            request.append(data ?? Data())
            guard error == nil, request.count < 16_384 else {
                connection.cancel()
                return
            }
            guard let text = String(data: request, encoding: .utf8), text.contains("\r\n\r\n") else {
                if complete { connection.cancel() } else { receive(connection, accumulated: request) }
                return
            }
            let path = String(text.split(separator: " ").dropFirst().first ?? "")
            lock.withLock { requestedPaths.append(path) }
            let redirect = redirects && path == "/health"
            let status = redirect ? "302 Found" : "200 OK"
            let location = redirect ? "Location: /destination\r\n" : ""
            let response = "HTTP/1.1 \(status)\r\n\(location)Content-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}

// MARK: - SOCKS5 recorder

/// Loopback SOCKS5 listener (RFC 1928 + RFC 1929 credentials) that records
/// each CONNECT target and then refuses the tunnel.
private final class SOCKS5Recorder: @unchecked Sendable {
    enum Connection: Equatable {
        case socks(username: String, password: String, host: String, port: UInt16)
    }

    enum RecorderError: Error, Equatable {
        case shortRead
        case unsupported(String)
        case timedOut
    }

    let port: UInt16
    private let listener: NWListener
    private let queue: DispatchQueue
    private let connections: AsyncStream<Result<Connection, Error>>

    private init(listener: NWListener, port: UInt16, queue: DispatchQueue, connections: AsyncStream<Result<Connection, Error>>) {
        self.listener = listener
        self.port = port
        self.queue = queue
        self.connections = connections
    }

    static func start() async throws -> SOCKS5Recorder {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "oppi.tests.socks5-recorder")
        let (stream, continuation) = AsyncStream<Result<Connection, Error>>.makeStream()

        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            Task {
                do {
                    continuation.yield(.success(try await Self.record(connection)))
                } catch {
                    continuation.yield(.failure(error))
                }
                connection.cancel()
            }
        }

        let port: UInt16 = try await withCheckedThrowingContinuation { ready in
            let resumed = LockedFlag()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.setOnce(), let port = listener.port?.rawValue { ready.resume(returning: port) }
                case .failed(let error):
                    if resumed.setOnce() { ready.resume(throwing: error) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        return SOCKS5Recorder(listener: listener, port: port, queue: queue, connections: stream)
    }

    func stop() {
        listener.cancel()
    }

    func nextConnection(timeout: Duration = .seconds(10)) async throws -> Connection {
        let connections = self.connections
        return try await withThrowingTaskGroup(of: Connection.self) { group in
            group.addTask {
                for await result in connections { return try result.get() }
                throw RecorderError.timedOut
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw RecorderError.timedOut
            }
            let first = try await group.next()
            group.cancelAll()
            return try #require(first)
        }
    }

    private static func record(_ connection: NWConnection) async throws -> Connection {
        let version = try await read(connection, count: 1)
        guard version == [0x05] else { throw RecorderError.unsupported("not SOCKS5: \(version)") }

        // Greeting: offered methods; choose username/password (0x02).
        let methodCount = Int(try await read(connection, count: 1)[0])
        let methods = try await read(connection, count: methodCount)
        guard methods.contains(0x02) else {
            try await send(connection, [0x05, 0xFF])
            throw RecorderError.unsupported("no username/password method offered: \(methods)")
        }
        try await send(connection, [0x05, 0x02])

        // RFC 1929 sub-negotiation.
        _ = try await read(connection, count: 1)
        let username = try await read(connection, count: Int(try await read(connection, count: 1)[0]))
        let password = try await read(connection, count: Int(try await read(connection, count: 1)[0]))
        try await send(connection, [0x01, 0x00])

        // CONNECT request.
        let header = try await read(connection, count: 4)
        guard header[1] == 0x01 else { throw RecorderError.unsupported("command \(header[1])") }
        let host: String
        switch header[3] {
        case 0x03:
            host = String(bytes: try await read(connection, count: Int(try await read(connection, count: 1)[0])), encoding: .utf8) ?? ""
        case 0x01:
            host = try await read(connection, count: 4).map(String.init).joined(separator: ".")
        default:
            throw RecorderError.unsupported("address type \(header[3])")
        }
        let portBytes = try await read(connection, count: 2)
        // Refuse the tunnel; the recorded target is the result.
        try await send(connection, [0x05, 0x05, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
        return .socks(
            username: String(bytes: username, encoding: .utf8) ?? "",
            password: String(bytes: password, encoding: .utf8) ?? "",
            host: host,
            port: UInt16(portBytes[0]) << 8 | UInt16(portBytes[1])
        )
    }

    private static func read(_ connection: NWConnection, count: Int) async throws -> [UInt8] {
        guard count > 0 else { return [] }
        return try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, data.count == count {
                    continuation.resume(returning: Array(data))
                } else {
                    continuation.resume(throwing: RecorderError.shortRead)
                }
            }
        }
    }

    private static func send(_ connection: NWConnection, _ bytes: [UInt8]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: Data(bytes), completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var isSet = false

    func setOnce() -> Bool {
        lock.withLock {
            defer { isSet = true }
            return !isSet
        }
    }
}
