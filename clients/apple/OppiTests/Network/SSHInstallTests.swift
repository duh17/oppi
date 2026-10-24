import Foundation
import Testing
@testable import Oppi

@Suite("Install & Start progress lines")
struct SSHInstallEventTests {
    @Test func stepLinesCarryStepStatusAndTheRestOfTheLineAsDetail() {
        #expect(SSHInstallEvent.parse("oppi-install: step=node status=begin detail=Downloading Node.js v22.20.0 (darwin-arm64)")
            == .step(.node, .begin, detail: "Downloading Node.js v22.20.0 (darwin-arm64)"))
        #expect(SSHInstallEvent.parse("oppi-install: step=service status=fail detail=loginctl enable-linger needs an admin: run sudo loginctl enable-linger chen")
            == .step(.service, .fail, detail: "loginctl enable-linger needs an admin: run sudo loginctl enable-linger chen"))
        #expect(SSHInstallEvent.parse("oppi-install: step=oppi status=skip detail=key=value stays in the detail")
            == .step(.oppi, .skip, detail: "key=value stays in the detail"))
        #expect(SSHInstallEvent.parse("oppi-install: step=start status=ok") == .step(.start, .ok, detail: ""))
        #expect(SSHInstallEvent.parse("oppi-install: step=service status=warn detail=stops at logout until an admin runs sudo loginctl enable-linger chen")
            == .step(.service, .warn, detail: "stops at logout until an admin runs sudo loginctl enable-linger chen"))
        // sshd output may arrive with CRLF.
        #expect(SSHInstallEvent.parse("oppi-install: step=oppi status=ok detail=0.31.0\r") == .step(.oppi, .ok, detail: "0.31.0"))
    }

    @Test func doneAndErrorLines() {
        #expect(SSHInstallEvent.parse("oppi-install: done version=0.31.0 port=7749") == .done(version: "0.31.0", port: 7749))
        #expect(SSHInstallEvent.parse("oppi-install: done version=0.31.0") == .done(version: "0.31.0", port: nil))
        #expect(SSHInstallEvent.parse("oppi-install: error code=checksum detail=SHASUMS256 mismatch for node-v22.20.0-linux-x64.tar.xz")
            == .error(code: "checksum", detail: "SHASUMS256 mismatch for node-v22.20.0-linux-x64.tar.xz"))
        #expect(SSHInstallEvent.parse("oppi-install: error code=start_timeout") == .error(code: "start_timeout", detail: ""))
    }

    @Test(arguments: [
        "",
        "added 212 packages in 14s",
        "[oppi-install] Installing dependencies",
        "  oppi-install: step=node status=ok detail=indented is human text",
        "oppi-install: step=rust status=ok detail=unknown step",
        "oppi-install: step=node status=maybe detail=unknown status",
        "oppi-install: step=node detail=no status",
        "oppi-install: done",
        "oppi-install: error detail=no code",
        "oppi-install: hello",
    ])
    func everythingElseIsIgnored(line: String) {
        #expect(SSHInstallEvent.parse(Substring(line)) == nil)
    }
}

@Suite("Install & Start output buffering")
struct SSHInstallLineBufferTests {
    @Test func linesSplitAcrossChunksAndCharactersSplitAcrossChunksArriveWhole() {
        var buffer = SSHInstallLineBuffer()
        let text = Data("npm warn ⚠︎\noppi-install: step=node status=begin detail=Téléchargement\nrest".utf8)
        var lines: [Substring] = []
        // One byte at a time splits every multi-byte character.
        for byte in text { lines += buffer.append(Data([byte])) }
        #expect(lines == ["npm warn ⚠︎", "oppi-install: step=node status=begin detail=Téléchargement"])
        #expect(buffer.append(Data("\n".utf8)) == ["rest"])
    }

    @Test func anOverlongLineIsDroppedAndTheNextLineStillArrives() {
        var buffer = SSHInstallLineBuffer()
        let long = Data(repeating: UInt8(ascii: "x"), count: SSHInstallLineBuffer.maximumLineBytes + 10)
        #expect(buffer.append(long).isEmpty)
        #expect(buffer.append(Data("still the long line\noppi-install: done version=1.0.0\n".utf8)) == ["oppi-install: done version=1.0.0"])
    }
}

@Suite("Install & Start outcome")
struct SSHInstallProgressTests {
    private static func progress(_ events: [SSHInstallEvent]) -> SSHInstallProgress {
        var progress = SSHInstallProgress()
        for event in events { progress.apply(event) }
        return progress
    }

    @Test func stepsMoveFromPendingThroughRunningToTheirResult() {
        var progress = SSHInstallProgress()
        #expect(progress.state(of: .node) == .pending)
        progress.apply(.step(.node, .begin, detail: "Downloading"))
        #expect(progress.state(of: .node) == .running("Downloading"))
        progress.apply(.step(.node, .skip, detail: "v22.20.0 already installed"))
        #expect(progress.state(of: .node) == .skipped("v22.20.0 already installed"))
        #expect(progress.state(of: .oppi) == .pending)
    }

    @Test func aWarnedStepStaysAWarningAndSetupStillSucceeds() {
        let progress = Self.progress([
            .step(.service, .begin, detail: ""),
            .step(.service, .warn, detail: "stops at logout"),
            .done(version: "0.31.0", port: 7749),
        ])
        #expect(progress.state(of: .service) == .warning("stops at logout"))
        #expect(progress.verdict(exitStatus: 0) == .success(.init(version: "0.31.0", port: 7749)))
    }

    @Test func doneWithExitZeroSucceeds() {
        let progress = Self.progress([.step(.start, .ok, detail: ""), .done(version: "0.31.0", port: 7749)])
        #expect(progress.verdict(exitStatus: 0) == .success(.init(version: "0.31.0", port: 7749)))
    }

    @Test func anErrorLineWinsAndFailsTheStepThatWasRunning() {
        let progress = Self.progress([
            .step(.node, .ok, detail: "v22.20.0"),
            .step(.oppi, .begin, detail: "npm install"),
            .error(code: "npm", detail: "ETIMEDOUT"),
        ])
        #expect(progress.state(of: .node) == .finished("v22.20.0"))
        #expect(progress.state(of: .oppi) == .failed("ETIMEDOUT"))
        for exit in [Optional(1), 0, nil] {
            #expect(progress.verdict(exitStatus: exit) == .failure(.installFailed(code: "npm", detail: "ETIMEDOUT")))
        }
    }

    @Test(arguments: [Optional(0), 1, 127, nil])
    func endingWithoutDoneIsIncomplete(exit: Int?) {
        // An old script that prints no progress, or a crash mid-way.
        let progress = Self.progress([.step(.node, .begin, detail: "")])
        #expect(progress.verdict(exitStatus: exit) == .failure(.installIncomplete(exitStatus: exit)))
    }

    @Test func aNonZeroExitAfterDoneIsIncomplete() {
        let progress = Self.progress([.done(version: "0.31.0", port: 7749)])
        #expect(progress.verdict(exitStatus: 2) == .failure(.installIncomplete(exitStatus: 2)))
    }
}

@Suite("Set Up a Computer address")
struct SSHSetupAddressTests {
    @Test(arguments: [
        ("studio.local", "studio.local", UInt16(22)),
        ("  studio.local  ", "studio.local", 22),
        ("127.0.0.1:2222", "127.0.0.1", 2222),
        ("studio.tail1234.ts.net:22", "studio.tail1234.ts.net", 22),
        ("fd7a:115c:a1e0::1", "fd7a:115c:a1e0::1", 22),
        ("[fd7a:115c:a1e0::1]:2200", "fd7a:115c:a1e0::1", 2200),
        ("[fd7a:115c:a1e0::1]", "fd7a:115c:a1e0::1", 22),
    ])
    func hostAndOptionalPort(text: String, host: String, port: UInt16) {
        #expect(SSHSetupAddress(text) == SSHSetupAddress(host: host, port: port))
    }

    @Test(arguments: ["", "   ", ":22", "studio:0", "studio:65536", "studio:ssh", "[::1", "[::1]x", "[]:22"])
    func invalidTextHasNoAddress(text: String) {
        #expect(SSHSetupAddress(text) == nil)
    }
}
