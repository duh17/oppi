import CryptoKit
import Darwin
import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import Security
import Synchronization
import Testing
@testable import Oppi

@Suite("NIOSSH public-key PTY session", .serialized)
struct SSHPTYSessionTests {
    @Test func unknownAndMismatchedHostKeysCloseBeforeUserAuthentication() async throws {
        for saved in [Optional<SSHHostKey>.none, SSHHostKey(openSSH: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMismatch") ] {
            let fixture = try await SSHFixture.start()
            defer { fixture.close() }
            do {
                _ = try await SSHPTYSession.connect(
                    configuration: fixture.clientConfiguration(savedHostKey: saved),
                    socket: fixture.clientSocket,
                    sink: { _ in }
                )
                Issue.record("Untrusted host key unexpectedly connected")
            } catch let error as SSHPTYSessionError {
                if saved == nil {
                    guard case .unknownHostKey = error else {
                        Issue.record("Expected unknown host key, got \(error)")
                        continue
                    }
                } else {
                    guard case .hostKeyMismatch = error else {
                        Issue.record("Expected host key mismatch, got \(error)")
                        continue
                    }
                }
            }
            #expect(fixture.authRequests == 0)
        }
    }

    @Test func keyExchangeFailureHasAnActionableMapping() async throws {
        let fixture = try await SSHFixture.start(failKeyExchange: true)
        defer { fixture.close() }

        do {
            _ = try await fixture.connect(sink: { _ in })
            Issue.record("Connection with no mutually supported algorithms unexpectedly succeeded")
        } catch let error as SSHPTYSessionError {
            guard case .unsupportedAlgorithms = error else {
                Issue.record("Expected key-exchange failure, got \(error)")
                return
            }
            #expect(error.message.contains("no supported algorithm"))
        }
    }

    @Test func passwordSignInSharesThePreflightOfferAndRejectsWithoutRetry() async throws {
        for credential in ["fixture-correct", "fixture-wrong"] {
            let fixture = try await SSHFixture.start(auth: .passwordOnly)
            defer { fixture.close() }
            do {
                let session = try await SSHPTYSession.connect(configuration: .init(
                    username: "fixture", authentication: .password(credential), savedHostKey: SSHHostKey(openSSH: String(openSSHPublicKey: fixture.hostKey.publicKey))
                ), socket: fixture.clientSocket, sink: { _ in })
                #expect(credential == "fixture-correct")
                #expect(fixture.channelRequests.prefix(2).elementsEqual(["pty", "shell"]))
                await session.cancel()
            } catch let error as SSHPTYSessionError {
                #expect(credential == "fixture-wrong")
                #expect(error == .authenticationFailed)
                #expect(fixture.channelRequests.isEmpty)
            }
            #expect(fixture.authKinds == ["password"])
        }
    }

    @Test func acceptedPublicKeyOpensPTYThenShellAndSupportsWindowChange() async throws {
        let fixture = try await SSHFixture.start()
        let collector = EventCollector()
        let session = try await fixture.connect(sink: collector.receive)
        defer { fixture.close() }

        #expect(fixture.authRequests == 1)
        #expect(fixture.authKinds == ["publickey"])
        #expect(fixture.channelRequests.prefix(2).elementsEqual(["pty", "shell"]))

        try await session.resize(columns: 132, rows: 43, pixelWidth: 1200, pixelHeight: 800)
        try await fixture.windowChanged.futureResult.get()
        #expect(fixture.lastWindow == .init(columns: 132, rows: 43, pixelWidth: 1200, pixelHeight: 800))
        await session.cancel()
    }

    @Test func rejectedPublicKeyNeverFallsBackToPassword() async throws {
        let fixture = try await SSHFixture.start(auth: .rejectPublicKey)
        defer { fixture.close() }

        await #expect(throws: SSHPTYSessionError.authenticationFailed) {
            _ = try await fixture.connect(sink: { _ in })
        }
        #expect(fixture.authRequests == 1)
        #expect(fixture.authKinds == ["publickey"])
    }

    @Test func passwordOnlyServerFailsClosedWithoutAnAuthenticationRequest() async throws {
        let fixture = try await SSHFixture.start(auth: .passwordOnly)
        defer { fixture.close() }

        await #expect(throws: SSHPTYSessionError.publicKeyNotAllowed) {
            _ = try await fixture.connect(sink: { _ in })
        }
        // NIOSSH starts with the configured public key before the server's
        // first failure advertises password-only. It must never offer password.
        #expect(fixture.authKinds == ["publickey"])
    }

    @Test func rejectedPTYReplySurfacesTheSpecificFailure() async throws {
        let fixture = try await SSHFixture.start(rejectPTY: true)
        defer { fixture.close() }

        await #expect(throws: SSHPTYSessionError.ptyRequestRejected) {
            _ = try await fixture.connect(sink: { _ in })
        }
        #expect(fixture.channelRequests == ["pty"])
    }

    @Test func inputBurstLargerThanReceiveWindowArrivesWithoutApplicationBuffering() async throws {
        let fixture = try await SSHFixture.start(maximumPacketSize: 32 * 1024, expectedInputBytes: 3 * 1024 * 1024)
        let collector = EventCollector()
        let session = try await fixture.connect(sink: collector.receive)
        defer { fixture.close() }

        // The advertised receive window is 64 × 32 KiB = 2 MiB. This single
        // write must be fragmented, become non-writable, and resume only after
        // window-adjust messages; the application owner queues no extra input.
        let burst = Data(repeating: 0x5A, count: 3 * 1024 * 1024)
        try await session.send(burst)
        try await fixture.inputReceived.futureResult.get()
        #expect(fixture.inputBytes == burst.count)
        #expect(collector.events.contains(.writabilityChanged(false)))
        #expect(collector.events.last(where: {
            if case .writabilityChanged = $0 { true } else { false }
        }) == .writabilityChanged(true))
        await session.cancel()
    }

    @Test func serverDroppingAfterAuthenticationBeforeThePTYOpensFailsConnect() async throws {
        // Regression: when opening the PTY channel throws before the child
        // handler is installed, the `ready` promise used to be dropped
        // uncompleted. NIO traps on that in Debug, which crashes the process.
        for _ in 0..<5 {
            let fixture = try await SSHFixture.start(closeAfterAuth: true)
            defer { fixture.close() }
            await #expect(throws: SSHPTYSessionError.self) {
                _ = try await fixture.connect(sink: { _ in })
            }
            #expect(fixture.authRequests == 1)
            #expect(fixture.channelRequests.isEmpty)
        }
    }

    @Test func failureOpeningThePTYChannelCompletesTheReadyPromise() async throws {
        // A parent channel with no NIOSSHHandler makes opening throw before the
        // child handler exists, as when the connection drops right after
        // sign-in. `ready` must still complete; the sentinel fails the test
        // instead of hanging or leaking the promise.
        var descriptors = [Int32](repeating: 0, count: 2)
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        defer { Darwin.close(descriptors[1]) }
        let loop = MultiThreadedEventLoopGroup.singleton.next()
        let parent = try await ClientBootstrap(group: loop).withConnectedSocket(descriptors[0]).get()
        defer { parent.close(promise: nil) }
        struct Hung: Error {}
        let ready = loop.makePromise(of: Void.self)
        let sentinel = loop.scheduleTask(in: .seconds(2)) { ready.fail(Hung()) }
        defer { sentinel.cancel() }

        await #expect(throws: (any Error).self) {
            _ = try await SSHPTYSession.openTerminal(
                on: parent,
                configuration: .init(
                    username: "u",
                    identity: SSHIdentity(privateKey: NIOSSHPrivateKey(p256Key: P256.Signing.PrivateKey()), isHardwareBacked: false),
                    savedHostKey: nil
                ),
                ready: ready,
                sink: { _ in }
            )
        }
        do {
            try await ready.futureResult.get()
            Issue.record("ready unexpectedly succeeded")
        } catch is Hung {
            Issue.record("ready was never completed when opening the PTY channel failed")
        } catch {}
    }

    @Test func exitStatusSentAfterEOFStillReachesTheEventStream() async throws {
        let fixture = try await SSHFixture.start()
        let collector = EventCollector()
        let session = try await fixture.connect(sink: collector.receive)
        defer { fixture.close() }

        fixture.finishTerminal(exitStatus: 3, eofBeforeExitStatus: true)
        try await collector.closed.futureResult.get()

        let terminalEvents = collector.events.filter {
            switch $0 {
            case .eof, .exitStatus, .closed: true
            default: false
            }
        }
        #expect(terminalEvents == [.eof, .exitStatus(3), .closed])
        await session.cancel()
    }

    @Test(.timeLimit(.minutes(1)))
    func slowConsumerBackpressuresRemoteOutputInsteadOfOverflowingOrDroppingBytes() async throws {
        let fixture = try await SSHFixture.start(maximumPacketSize: 32 * 1024)
        defer { fixture.close() }
        // 12 MiB is three times the queue's fail-loud ceiling. The consumer is far
        // slower than loopback, so without read backpressure the queue overflows.
        let queue = SSHTerminalEventQueue()
        let session = try await fixture.connect(flow: queue.flow, sink: queue.push)
        let total = 12 * 1024 * 1024
        let chunkSize = 64 * 1024

        let sender = Task {
            var offset = 0
            while offset < total {
                var chunk = Data(count: chunkSize)
                chunk.withUnsafeMutableBytes { buffer in
                    for index in 0..<buffer.count { buffer[index] = backpressurePattern(at: offset + index) }
                }
                try await fixture.send(chunk)
                offset += chunkSize
            }
            fixture.finishTerminal(exitStatus: 0)
        }

        var received = 0
        var mismatches = 0
        var receivedWhenExitReported: Int?
        var events = [SSHPTYEvent]()
        var firstBatch = true
        for await _ in queue.wake {
            let items = queue.drain()
            var batchBytes = 0
            for item in items {
                switch item {
                case .event(.data(let bytes)):
                    for (index, byte) in bytes.enumerated() where byte != backpressurePattern(at: received + index) { mismatches += 1 }
                    received += bytes.count
                    batchBytes += bytes.count
                case .event(let event):
                    events.append(event)
                    if case .exitStatus = event { receivedWhenExitReported = received }
                case .overflow:
                    Issue.record("Queue overflowed: remote output was not slowed by backpressure")
                }
            }
            // A stalled main actor on the first batch, then a slow consumer.
            try await Task.sleep(for: firstBatch ? .milliseconds(1500) : .milliseconds(20))
            firstBatch = false
            queue.release(bytes: batchBytes)
        }
        try await sender.value

        #expect(received == total)
        #expect(mismatches == 0)
        // Exit status is reported only after every byte that preceded it.
        #expect(receivedWhenExitReported == total)
        #expect(events.contains(.exitStatus(0)))
        #expect(events.last == .closed)
        // Bounded by the low-water mark plus one 2 MiB receive window, not by the volume.
        #expect(queue.peakQueuedBytes < 3 * 1024 * 1024)
        await session.cancel()
    }

    @Test func presenceEvaluationPrecedesDialAndSignInDeadline() async throws {
        let context = ControlledPresenceContext()
        let fixture = try await SSHFixture.start(auth: .passwordOnly)
        defer { fixture.close() }
        let dialed = Mutex(false)
        let connecting = Task {
            try await SSHPTYSession.connect(
                username: "fixture", savedHostKey: SSHHostKey(openSSH: String(openSSHPublicKey: fixture.hostKey.publicKey)),
                prepareAuthentication: {
                    _ = try await SSHIdentityKeyStore.authenticatedIdentity(context: context)
                    return .password("fixture-correct")
                }, dial: {
                    #expect(context.evaluated.withLock { $0 })
                    dialed.withLock { $0 = true }
                    return fixture.clientSocket
                }, sink: { _ in }
            )
        }
        await context.started.first(where: { _ in true })
        #expect(!dialed.withLock { $0 })
        #expect(fixture.authRequests == 0)
        // Presence outlasts the actual 20 s network sign-in timeout. Once
        // approved, a fresh deadline must still allow authentication to finish.
        try await Task.sleep(for: .seconds(21))
        #expect(!dialed.withLock { $0 })
        context.approve()
        let session = try await connecting.value
        #expect(dialed.withLock { $0 })
        #expect(fixture.authRequests == 1)
        await session.cancel()
    }

    @Test func cancellationDuringPresenceInvalidatesContextAndNeverDialsEvenAfterApproval() async throws {
        let context = ControlledPresenceContext()
        let dialed = Mutex(false)
        let connecting = Task {
            try await SSHPTYSession.connect(
                username: "fixture", savedHostKey: nil,
                prepareAuthentication: { .deviceKey(try await SSHIdentityKeyStore.authenticatedIdentity(context: context)) },
                dial: { dialed.withLock { $0 = true }; throw SSHPTYSessionError.connectionClosed },
                sink: { _ in }
            )
        }
        await context.started.first(where: { _ in true })
        connecting.cancel()
        context.approve() // adversarial late success from the system sheet
        await #expect(throws: CancellationError.self) { _ = try await connecting.value }
        #expect(context.invalidated.withLock { $0 })
        #expect(!context.loaded.withLock { $0 })
        #expect(!dialed.withLock { $0 })
    }

    @Test func missingEnclaveKeyRequiresExplicitReplacementButTransientErrorsPreserveSealedData() throws {
        for status in [errSecItemNotFound, errSecInteractionNotAllowed, errSecUserCanceled, errSecAuthFailed, errSecDecode] {
            let storage = MemorySSHIdentityStorage()
            let sealed = Data([1, 2, 3])
            try storage.save(sealed)
            let expected: SSHIdentityKeyStoreError = status == errSecItemNotFound ? .devicePasscodeChanged : .keychain(status)
            #expect(throws: expected) {
                let _: Data = try SSHIdentityKeyStore.restore(sealed: sealed, storage: storage) { _ in
                    throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
                }
            }
            if status == errSecItemNotFound {
                #expect(throws: SSHIdentityKeyStoreError.devicePasscodeChanged) { _ = try storage.load() }
                #expect(throws: SSHIdentityKeyStoreError.devicePasscodeChanged) { _ = try SSHIdentityKeyStore.loadOrCreate(storage: storage) }
                let replacement = try SSHIdentityKeyStore.loadOrCreate(storage: storage, createReplacement: true)
                #expect(replacement.publicKeyOpenSSH == (try SSHIdentityKeyStore.loadOrCreate(storage: storage)).publicKeyOpenSSH)
            } else {
                #expect(try storage.load() == sealed)
            }
            #expect(!expected.localizedDescription.contains("couldn’t be completed"))
        }
        #expect(SSHPTYSession.mapFailure(NSError(domain: NSOSStatusErrorDomain, code: Int(errSecInteractionNotAllowed)))
            == .keyExchangeFailed(SSHIdentityKeyStoreError.authenticationExpired.localizedDescription))
        #expect(SSHIdentityKeyStoreError.devicePasscodeChanged.localizedDescription == "Device passcode changed — create a new key")
    }

    @Test func realKeychainRemovesLegacySharedIdentityAndPersistsReplacementState() throws {
        func query(_ account: String, legacy: Bool = false) -> [String: Any] {
            var value: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: SharedConstants.keychainService,
                kSecAttrAccount as String: account,
            ]
            if legacy { value[kSecAttrAccessGroup as String] = SharedConstants.keychainAccessGroup }
            return value
        }
        let legacy = query("oppi.ssh.identity.v1", legacy: true)
        let current = query("oppi.ssh.identity.presence.v2")
        let marker = query("oppi.ssh.identity.replacement-required")
        defer { for item in [legacy, current, marker] { SecItemDelete(item as CFDictionary) } }
        var add = legacy
        add[kSecValueData as String] = Data([7])
        SecItemDelete(legacy as CFDictionary)
        #expect(SecItemAdd(add as CFDictionary, nil) == errSecSuccess)
        let storage = KeychainSSHIdentityStorage()
        try storage.save(Data([2, 3]))
        #expect(try storage.load() == Data([2, 3]))
        #expect(SecItemCopyMatching(legacy as CFDictionary, nil) == errSecItemNotFound)
        #expect(try storage.load() == Data([2, 3])) // legacy not-found is harmless
        try storage.requireReplacement()
        #expect(SecItemCopyMatching(current as CFDictionary, nil) == errSecItemNotFound)
        #expect(throws: SSHIdentityKeyStoreError.devicePasscodeChanged) { _ = try KeychainSSHIdentityStorage().load() }
        _ = try SSHIdentityKeyStore.loadOrCreate(storage: storage, createReplacement: true)
        #expect(SecItemCopyMatching(marker as CFDictionary, nil) == errSecItemNotFound)
        #expect(try storage.load() != nil)
    }

    @Test func simulatorIdentityIsPersistentExportableAndExplicitlySoftwareBacked() throws {
        let storage = MemorySSHIdentityStorage()
        let first = try SSHIdentityKeyStore.loadOrCreate(storage: storage)
        let second = try SSHIdentityKeyStore.loadOrCreate(storage: storage)

        #expect(!first.isHardwareBacked)
        #expect(first.backingDescription.contains("not hardware-backed"))
        #expect(first.publicKeyOpenSSH == second.publicKeyOpenSSH)
        #expect(first.publicKeyOpenSSH.hasPrefix("ecdsa-sha2-nistp256 "))
        #expect(first.publicKeyOpenSSH.hasSuffix(" oppi-ios"))
    }

    @Test func bytesEOFExitStatusCloseAndCancelAreReportedAndCloseEverything() async throws {
        let fixture = try await SSHFixture.start()
        let collector = EventCollector()
        let session = try await fixture.connect(sink: collector.receive)
        defer { fixture.close() }

        try await fixture.send(Data("hello".utf8))
        fixture.finishTerminal(exitStatus: 7)
        try await collector.closed.futureResult.get()

        let events = collector.events
        #expect(events.contains(.data(Data("hello".utf8))))
        #expect(events.contains(.exitStatus(7)))
        #expect(events.contains(.eof))
        #expect(events.contains(.closed))

        await session.cancel()
        await session.cancel()
        try await fixture.clientClosed.futureResult.get()
        await #expect(throws: SSHPTYSessionError.notConnected) {
            try await session.send(Data([1]))
        }
    }
}

private func backpressurePattern(at offset: Int) -> UInt8 {
    UInt8(truncatingIfNeeded: offset ^ (offset >> 8) ^ (offset >> 16))
}

private final class MemorySSHIdentityStorage: SSHIdentitySealedStorage, @unchecked Sendable {
    private let sealed = Mutex<Data?>(nil)
    private let replacement = Mutex(false)

    func load() throws -> Data? {
        if replacement.withLock({ $0 }) { throw SSHIdentityKeyStoreError.devicePasscodeChanged }
        return sealed.withLock { $0 }
    }
    func save(_ data: Data) throws {
        sealed.withLock { $0 = data }
        replacement.withLock { $0 = false }
    }
    func requireReplacement() throws {
        replacement.withLock { $0 = true }
        sealed.withLock { $0 = nil }
    }
}

private final class ControlledPresenceContext: SSHKeyPresenceContext, Sendable {
    let evaluated = Mutex(false)
    let invalidated = Mutex(false)
    let loaded = Mutex(false)
    let started: AsyncStream<Void>
    private let start: AsyncStream<Void>.Continuation
    private let approval: AsyncStream<Void>
    private let completion: AsyncStream<Void>.Continuation

    init() {
        (started, start) = AsyncStream.makeStream()
        (approval, completion) = AsyncStream.makeStream()
    }
    func evaluate() async throws {
        start.yield(())
        // Intentionally ignore cancellation, as a late system success can race
        // invalidate(). The production owner must check cancellation itself.
        await withCheckedContinuation { continuation in
            Task.detached {
                await self.approval.first(where: { _ in true })
                self.evaluated.withLock { $0 = true }
                continuation.resume()
            }
        }
    }
    func identity() throws -> SSHIdentity {
        loaded.withLock { $0 = true }
        return SSHIdentity(privateKey: NIOSSHPrivateKey(p256Key: P256.Signing.PrivateKey()), isHardwareBacked: false)
    }
    func invalidate() { invalidated.withLock { $0 = true } }
    func approve() { completion.yield(()) }
}

private final class EventCollector: @unchecked Sendable {
    private let storage = Mutex<[SSHPTYEvent]>([])
    private let loop = MultiThreadedEventLoopGroup.singleton.next()
    lazy var closed = loop.makePromise(of: Void.self)

    var events: [SSHPTYEvent] { storage.withLock { $0 } }

    func receive(_ event: SSHPTYEvent) {
        storage.withLock { $0.append(event) }
        if event == .closed { closed.succeed(()) }
    }
}

private final class SSHFixture: @unchecked Sendable {
    enum Authentication: Equatable {
        case acceptPublicKey
        case rejectPublicKey
        case passwordOnly
    }

    struct Window: Equatable, Sendable {
        let columns: Int
        let rows: Int
        let pixelWidth: Int
        let pixelHeight: Int
    }

    let clientSocket: Int32
    let hostKey: NIOSSHPrivateKey
    let userKey: NIOSSHPrivateKey
    let state: State
    private let server: Channel

    var authRequests: Int { state.authRequests.withLock { $0 } }
    var authKinds: [String] { state.authKinds.withLock { $0 } }
    var channelRequests: [String] { state.channelRequests.withLock { $0 } }
    var lastWindow: Window? { state.lastWindow.withLock { $0 } }
    var inputBytes: Int { state.inputBytes.withLock { $0 } }
    var windowChanged: EventLoopPromise<Void> { state.windowChanged }
    var inputReceived: EventLoopPromise<Void> { state.inputReceived }
    var clientClosed: EventLoopPromise<Void> { state.clientClosed }

    static func start(
        auth: Authentication = .acceptPublicKey,
        rejectPTY: Bool = false,
        maximumPacketSize: Int = 128 * 1024,
        expectedInputBytes: Int = 0,
        failKeyExchange: Bool = false,
        closeAfterAuth: Bool = false
    ) async throws -> SSHFixture {
        var descriptors = [Int32](repeating: 0, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw POSIXError(.ENOTCONN)
        }

        let hostKey = NIOSSHPrivateKey(p256Key: P256.Signing.PrivateKey())
        let userKey = NIOSSHPrivateKey(p256Key: P256.Signing.PrivateKey())
        let loop = MultiThreadedEventLoopGroup.singleton.next()
        let state = State(
            loop: loop,
            acceptedKey: userKey.publicKey,
            auth: auth,
            rejectPTY: rejectPTY,
            expectedInputBytes: expectedInputBytes,
            closeAfterAuth: closeAfterAuth
        )
        do {
            let server = try await ClientBootstrap(group: loop)
                .channelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        var configuration = SSHServerConfiguration(
                            hostKeys: [hostKey],
                            userAuthDelegate: FixtureAuthDelegate(state: state)
                        )
                        configuration.maximumPacketSize = maximumPacketSize
                        if failKeyExchange { configuration.transportProtectionSchemes = [] }
                        let ssh = NIOSSHHandler(
                            role: .server(configuration),
                            allocator: channel.allocator
                        ) { child, _ in
                            child.eventLoop.makeCompletedFuture {
                                state.terminal.withLock { $0 = child }
                                try child.pipeline.syncOperations.addHandler(FixtureTerminalHandler(state: state))
                            }
                        }
                        state.parent.withLock { $0 = channel }
                        try channel.pipeline.syncOperations.addHandlers(ssh, FixtureErrorHandler())
                    }
                }
                .withConnectedSocket(descriptors[0])
                .get()
            server.closeFuture.whenComplete { _ in state.clientClosed.succeed(()) }
            return SSHFixture(
                clientSocket: descriptors[1],
                hostKey: hostKey,
                userKey: userKey,
                state: state,
                server: server
            )
        } catch {
            Darwin.close(descriptors[0])
            Darwin.close(descriptors[1])
            throw error
        }
    }

    private init(clientSocket: Int32, hostKey: NIOSSHPrivateKey, userKey: NIOSSHPrivateKey, state: State, server: Channel) {
        self.clientSocket = clientSocket
        self.hostKey = hostKey
        self.userKey = userKey
        self.state = state
        self.server = server
    }

    func clientConfiguration(savedHostKey: SSHHostKey?) -> SSHPTYConfiguration {
        SSHPTYConfiguration(
            username: "fixture-user",
            identity: SSHIdentity(privateKey: userKey, isHardwareBacked: false),
            savedHostKey: savedHostKey
        )
    }

    func connect(flow: SSHPTYInboundFlow? = nil, sink: @escaping SSHPTYByteSink) async throws -> SSHPTYSession {
        var configuration = clientConfiguration(
            savedHostKey: SSHHostKey(openSSH: String(openSSHPublicKey: hostKey.publicKey))
        )
        configuration.inboundFlow = flow
        return try await SSHPTYSession.connect(
            configuration: configuration,
            socket: clientSocket,
            sink: sink
        )
    }

    func send(_ bytes: Data) async throws {
        let terminal = try #require(state.terminal.withLock { $0 })
        var buffer = terminal.allocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        try await terminal.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(buffer))).get()
    }

    func finishTerminal(exitStatus: Int, eofBeforeExitStatus: Bool = false) {
        guard let terminal = state.terminal.withLock({ $0 }) else { return }
        terminal.eventLoop.execute {
            let exit = SSHChannelRequestEvent.ExitStatus(exitStatus: exitStatus)
            if eofBeforeExitStatus {
                let eof = terminal.eventLoop.makePromise(of: Void.self)
                terminal.close(mode: .output, promise: eof)
                eof.futureResult.whenComplete { _ in
                    terminal.triggerUserOutboundEvent(exit, promise: nil)
                    terminal.close(promise: nil)
                }
            } else {
                terminal.triggerUserOutboundEvent(exit, promise: nil)
                let eof = terminal.eventLoop.makePromise(of: Void.self)
                terminal.close(mode: .output, promise: eof)
                eof.futureResult.whenComplete { _ in terminal.close(promise: nil) }
            }
        }
    }

    func close() {
        // Every fixture signal is a real promise so an unexpectedly skipped
        // branch is diagnosed by assertions rather than leaked by teardown.
        state.windowChanged.succeed(())
        state.inputReceived.succeed(())
        state.clientClosed.succeed(())
        server.close(promise: nil)
    }

    final class State: @unchecked Sendable {
        let acceptedKey: NIOSSHPublicKey
        let auth: Authentication
        let rejectPTY: Bool
        let expectedInputBytes: Int
        let closeAfterAuth: Bool
        let parent = Mutex<Channel?>(nil)
        let authRequests = Mutex(0)
        let authKinds = Mutex<[String]>([])
        let channelRequests = Mutex<[String]>([])
        let lastWindow = Mutex<Window?>(nil)
        let inputBytes = Mutex(0)
        let terminal = Mutex<Channel?>(nil)
        let windowChanged: EventLoopPromise<Void>
        let inputReceived: EventLoopPromise<Void>
        let clientClosed: EventLoopPromise<Void>

        init(
            loop: EventLoop,
            acceptedKey: NIOSSHPublicKey,
            auth: Authentication,
            rejectPTY: Bool,
            expectedInputBytes: Int,
            closeAfterAuth: Bool
        ) {
            self.closeAfterAuth = closeAfterAuth
            self.acceptedKey = acceptedKey
            self.auth = auth
            self.rejectPTY = rejectPTY
            self.expectedInputBytes = expectedInputBytes
            windowChanged = loop.makePromise(of: Void.self)
            inputReceived = loop.makePromise(of: Void.self)
            clientClosed = loop.makePromise(of: Void.self)
        }
    }
}

private final class FixtureAuthDelegate: NIOSSHServerUserAuthenticationDelegate {
    private let state: SSHFixture.State

    init(state: SSHFixture.State) {
        self.state = state
    }

    var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods {
        switch state.auth {
        case .passwordOnly: .password
        case .acceptPublicKey, .rejectPublicKey: .publicKey
        }
    }

    func requestReceived(
        request: NIOSSHUserAuthenticationRequest,
        responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>
    ) {
        state.authRequests.withLock { $0 += 1 }
        switch request.request {
        case .publicKey(let key):
            state.authKinds.withLock { $0.append("publickey") }
            guard state.auth == .acceptPublicKey, key.publicKey == state.acceptedKey else {
                responsePromise.succeed(.failure)
                return
            }
            responsePromise.succeed(.success)
            if state.closeAfterAuth {
                // Registered after NIOSSH's own completion callback, so the
                // success reply is already flushed when the socket closes.
                responsePromise.futureResult.whenSuccess { [state] _ in
                    state.parent.withLock { $0 }?.close(promise: nil)
                }
            }
        case .password(let password):
            state.authKinds.withLock { $0.append("password") }
            responsePromise.succeed(state.auth == .passwordOnly && password.password == "fixture-correct" ? .success : .failure)
        case .none:
            state.authKinds.withLock { $0.append("none") }
            responsePromise.succeed(.failure)
        case .hostBased:
            state.authKinds.withLock { $0.append("hostbased") }
            responsePromise.succeed(.failure)
        }
    }
}

private final class FixtureTerminalHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData

    private let state: SSHFixture.State
    private var sawPTY = false

    init(state: SSHFixture.State) {
        self.state = state
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is SSHChannelRequestEvent.PseudoTerminalRequest:
            state.channelRequests.withLock { $0.append("pty") }
            if state.rejectPTY {
                context.triggerUserOutboundEvent(ChannelFailureEvent(), promise: nil)
            } else {
                sawPTY = true
                context.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil)
            }
        case is SSHChannelRequestEvent.ShellRequest:
            state.channelRequests.withLock { $0.append("shell") }
            if sawPTY {
                context.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil)
            } else {
                context.triggerUserOutboundEvent(ChannelFailureEvent(), promise: nil)
            }
        case let resize as SSHChannelRequestEvent.WindowChangeRequest:
            state.channelRequests.withLock { $0.append("window-change") }
            state.lastWindow.withLock {
                $0 = .init(
                    columns: resize.terminalCharacterWidth,
                    rows: resize.terminalRowHeight,
                    pixelWidth: resize.terminalPixelWidth,
                    pixelHeight: resize.terminalPixelHeight
                )
            }
            state.windowChanged.succeed(())
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard message.type == .channel, case .byteBuffer(let buffer) = message.data else { return }
        let total = state.inputBytes.withLock { count -> Int in
            count += buffer.readableBytes
            return count
        }
        if state.expectedInputBytes > 0, total >= state.expectedInputBytes {
            state.inputReceived.succeed(())
        }
    }
}

private final class FixtureErrorHandler: ChannelInboundHandler {
    typealias InboundIn = Any

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        context.close(promise: nil)
    }
}
