import Darwin
import Foundation
import OSLog

/// Companion-owned Unix-domain still fetch. Not the Oppi server local API socket.
/// Fetch never starts a capture. Sharing stays default-off on the session gate.
final class DesktopCompanionOwnerSocket: @unchecked Sendable {
    static let processInstanceToken = UUID().uuidString

    let shareGate: DesktopStillShareGate
    let runtimeRoot: URL
    let runtimeDirectory: URL
    let socketPath: String
    let lockPath: String

    private(set) var socketAddressFamily: Int32 = 0

    private let peerAuthorizer: any DesktopOwnerSocketPeerAuthorizing
    private let stateLock = NSLock()
    private let acceptQueue = DispatchQueue(label: "dev.chenda.OppiDesktopCompanion.owner-socket")
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "OppiDesktopCompanion",
        category: "OwnerSocket"
    )

    private var listenFD: Int32 = -1
    private var stopped = true
    private var started = false
    private var heldLock: HeldSocketLock?
    private var socketIdentity: SocketIdentity?

    init(
        shareGate: DesktopStillShareGate,
        runtimeRoot: URL = DesktopCompanionOwnerSocketPath.defaultRuntimeRoot(),
        peerAuthorizer: any DesktopOwnerSocketPeerAuthorizing = SameUserDesktopOwnerSocketPeerAuthorizer()
    ) {
        self.shareGate = shareGate
        self.runtimeRoot = runtimeRoot
        self.peerAuthorizer = peerAuthorizer
        let socketURL = DesktopCompanionOwnerSocketPath.socketURL(runtimeRoot: runtimeRoot)
        runtimeDirectory = socketURL.deletingLastPathComponent()
        socketPath = socketURL.path
        lockPath = socketPath + ".lock"
    }

    func start() throws {
        stateLock.lock()
        if started {
            stateLock.unlock()
            throw DesktopCompanionOwnerSocketError.alreadyOwned(pid: getpid())
        }
        started = true
        stopped = false
        stateLock.unlock()

        do {
            try DesktopCompanionOwnerSocketPath.ensurePrivateRuntimeDirectory(runtimeDirectory)
            let lock = try acquireLock()
            stateLock.lock()
            heldLock = lock
            stateLock.unlock()

            try removeStaleSocket()

            let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw DesktopCompanionOwnerSocketError.bindFailed }
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)

            do {
                try bindUnix(fd: fd, path: socketPath)
                try chmodPath(socketPath, mode: 0o600)
                guard Darwin.listen(fd, 8) == 0 else {
                    throw DesktopCompanionOwnerSocketError.listenFailed
                }
                try chmodPath(socketPath, mode: 0o600)

                var addr = sockaddr_storage()
                var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
                let nameResult = withUnsafeMutablePointer(to: &addr) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                        Darwin.getsockname(fd, sockPtr, &length)
                    }
                }
                guard nameResult == 0, Int32(addr.ss_family) == AF_UNIX else {
                    throw DesktopCompanionOwnerSocketError.bindFailed
                }

                var st = stat()
                guard lstat(socketPath, &st) == 0, (st.st_mode & S_IFMT) == S_IFSOCK else {
                    throw DesktopCompanionOwnerSocketError.notASocket
                }

                stateLock.lock()
                listenFD = fd
                socketAddressFamily = AF_UNIX
                socketIdentity = SocketIdentity(dev: st.st_dev, ino: st.st_ino)
                stateLock.unlock()
            } catch {
                Darwin.close(fd)
                unlinkOwnedSocket()
                throw error
            }

            acceptQueue.async { [weak self] in
                self?.acceptLoop()
            }
            logger.info("Owner socket listening")
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        stateLock.lock()
        let alreadyStopped = stopped && listenFD < 0 && heldLock == nil && !started
        if alreadyStopped {
            stateLock.unlock()
            return
        }
        stopped = true
        started = false
        let fd = listenFD
        listenFD = -1
        let identity = socketIdentity
        socketIdentity = nil
        let lock = heldLock
        heldLock = nil
        socketAddressFamily = 0
        stateLock.unlock()

        if fd >= 0 {
            Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
        removeSocket(identity: identity)
        lock?.release()
    }

    deinit {
        stop()
    }

    private func acceptLoop() {
        while true {
            stateLock.lock()
            let fd = listenFD
            let isStopped = stopped
            stateLock.unlock()
            if isStopped || fd < 0 { return }

            var addr = sockaddr_un()
            var length = socklen_t(MemoryLayout<sockaddr_un>.size)
            let client = withUnsafeMutablePointer(to: &addr) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    Darwin.accept(fd, sockPtr, &length)
                }
            }
            if client < 0 {
                if errno == EINTR { continue }
                stateLock.lock()
                let isStoppedNow = stopped
                stateLock.unlock()
                if isStoppedNow { return }
                continue
            }
            handle(clientFD: client)
        }
    }

    private func handle(clientFD: Int32) {
        defer { Darwin.close(clientFD) }
        var nosig = Int32(1)
        _ = setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout<Int32>.size))

        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(clientFD, &uid, &gid) == 0, peerAuthorizer.isAuthorized(uid: uid) else {
            writeResponse(
                fd: clientFD,
                status: 403,
                reason: "Forbidden",
                contentType: "text/plain; charset=utf-8",
                headers: [:],
                body: Data("unauthorized\n".utf8)
            )
            return
        }

        guard let request = readRequest(fd: clientFD) else {
            writeResponse(
                fd: clientFD,
                status: 400,
                reason: "Bad Request",
                contentType: "text/plain; charset=utf-8",
                headers: [:],
                body: Data("bad request\n".utf8)
            )
            return
        }

        guard request.method == "GET" else {
            writeResponse(
                fd: clientFD,
                status: 405,
                reason: "Method Not Allowed",
                contentType: "text/plain; charset=utf-8",
                headers: ["Allow": "GET"],
                body: Data("method not allowed\n".utf8)
            )
            return
        }

        if request.path == "/still/current" {
            writeStillFetch(fd: clientFD, result: shareGate.fetchCurrent())
            return
        }

        guard let captureID = stillCaptureID(from: request.path) else {
            writeResponse(
                fd: clientFD,
                status: 404,
                reason: "Not Found",
                contentType: "text/plain; charset=utf-8",
                headers: [:],
                body: Data("not found\n".utf8)
            )
            return
        }

        writeStillFetch(fd: clientFD, result: shareGate.fetch(captureID: captureID))
    }

    private func writeStillFetch(
        fd: Int32,
        result: Result<DesktopSharedStill, DesktopStillShareFetchFailure>
    ) {
        switch result {
        case .failure(.sharingDisabled):
            writeResponse(
                fd: fd,
                status: 403,
                reason: "Forbidden",
                contentType: "text/plain; charset=utf-8",
                headers: [:],
                body: Data("sharing disabled\n".utf8)
            )
        case .failure(.staleCaptureID):
            writeResponse(
                fd: fd,
                status: 404,
                reason: "Not Found",
                contentType: "text/plain; charset=utf-8",
                headers: [:],
                body: Data("stale capture\n".utf8)
            )
        case .success(let still):
            writeResponse(
                fd: fd,
                status: 200,
                reason: "OK",
                contentType: "image/png",
                headers: [
                    DesktopStillShareHTTP.captureID: still.captureID.uuidString,
                    DesktopStillShareHTTP.surfaceWindowID: String(still.surfaceID.windowID),
                    DesktopStillShareHTTP.surfaceTitle: DesktopStillShareHTTP.headerTitle(still.surfaceTitle),
                    DesktopStillShareHTTP.capturedAt: DesktopStillShareHTTP.date(still.capturedAt),
                    DesktopStillShareHTTP.width: String(still.width),
                    DesktopStillShareHTTP.height: String(still.height),
                    DesktopStillShareHTTP.caption: still.caption,
                    "Cache-Control": "no-store",
                ],
                body: still.pngData
            )
        }
    }

    private func stillCaptureID(from path: String) -> UUID? {
        let prefix = "/still/"
        guard path.hasPrefix(prefix) else { return nil }
        let rest = String(path.dropFirst(prefix.count))
        guard !rest.contains("?"), !rest.contains("/") else { return nil }
        return UUID(uuidString: rest)
    }

    private func readRequest(fd: Int32) -> (method: String, path: String)? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4_096)
        let separator = Data("\r\n\r\n".utf8)
        while buffer.range(of: separator) == nil, buffer.count < 65_536 {
            let readCount = chunk.withUnsafeMutableBytes { raw in
                Darwin.read(fd, raw.baseAddress, raw.count)
            }
            if readCount < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if readCount == 0 { break }
            buffer.append(contentsOf: chunk.prefix(readCount))
        }
        guard let headerRange = buffer.range(of: separator),
              let headerText = String(
                data: buffer.subdata(in: buffer.startIndex..<headerRange.lowerBound),
                encoding: .utf8
              )
        else {
            return nil
        }
        let lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        return (String(parts[0]), String(parts[1]))
    }

    private func writeResponse(
        fd: Int32,
        status: Int,
        reason: String,
        contentType: String,
        headers: [String: String],
        body: Data
    ) {
        var header = "HTTP/1.1 \(status) \(reason)\r\n"
        var all = headers
        all["Content-Type"] = contentType
        all["Content-Length"] = String(body.count)
        all["Connection"] = "close"
        for key in all.keys.sorted() {
            header += "\(key): \(all[key] ?? "")\r\n"
        }
        header += "\r\n"
        var data = Data(header.utf8)
        data.append(body)
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.write(fd, base.advanced(by: offset), data.count - offset)
            }
            if written < 0 {
                if errno == EINTR { continue }
                return
            }
            if written == 0 { return }
            offset += written
        }
    }

    private func acquireLock() throws -> HeldSocketLock {
        let record = SocketLockRecord(
            pid: getpid(),
            token: UUID().uuidString,
            processInstanceToken: Self.processInstanceToken
        )
        let serialized = try JSONEncoder().encode(record) + Data("\n".utf8)

        for _ in 0..<3 {
            let fd = open(lockPath, O_CREAT | O_EXCL | O_WRONLY, 0o600)
            if fd >= 0 {
                defer { Darwin.close(fd) }
                let written = serialized.withUnsafeBytes { raw -> Int in
                    guard let base = raw.baseAddress else { return -1 }
                    return Darwin.write(fd, base, serialized.count)
                }
                guard written == serialized.count else {
                    unlink(lockPath)
                    throw DesktopCompanionOwnerSocketError.lockFailed
                }
                try chmodPath(lockPath, mode: 0o600)
                return HeldSocketLock(path: lockPath, serialized: serialized)
            }
            if errno != EEXIST {
                throw DesktopCompanionOwnerSocketError.lockFailed
            }

            let existing = try readLock()
            let currentProcessOwnsLock =
                existing.record.pid == getpid()
                && existing.record.processInstanceToken == Self.processInstanceToken
            if currentProcessOwnsLock
                || (existing.record.pid != getpid() && isProcessRunning(existing.record.pid))
            {
                throw DesktopCompanionOwnerSocketError.alreadyOwned(pid: existing.record.pid)
            }
            if let current = try? Data(contentsOf: URL(fileURLWithPath: lockPath)),
               current == existing.serialized
            {
                unlink(lockPath)
            }
        }
        throw DesktopCompanionOwnerSocketError.lockFailed
    }

    private func readLock() throws -> (record: SocketLockRecord, serialized: Data) {
        var st = stat()
        guard lstat(lockPath, &st) == 0 else { throw DesktopCompanionOwnerSocketError.lockFailed }
        guard (st.st_mode & S_IFMT) == S_IFREG else { throw DesktopCompanionOwnerSocketError.lockFailed }
        guard st.st_uid == getuid() else { throw DesktopCompanionOwnerSocketError.runtimeDirectoryNotOwned }
        let serialized = try Data(contentsOf: URL(fileURLWithPath: lockPath))
        let trimmed: Data
        if let newline = serialized.firstIndex(of: UInt8(ascii: "\n")) {
            trimmed = Data(serialized[..<newline])
        } else {
            trimmed = serialized
        }
        let record = try JSONDecoder().decode(SocketLockRecord.self, from: trimmed)
        return (record, serialized)
    }

    private func removeStaleSocket() throws {
        var st = stat()
        if lstat(socketPath, &st) != 0 {
            if errno == ENOENT { return }
            throw DesktopCompanionOwnerSocketError.bindFailed
        }
        guard (st.st_mode & S_IFMT) == S_IFSOCK else {
            throw DesktopCompanionOwnerSocketError.notASocket
        }
        guard st.st_uid == getuid() else {
            throw DesktopCompanionOwnerSocketError.runtimeDirectoryNotOwned
        }
        if canConnect(path: socketPath) {
            throw DesktopCompanionOwnerSocketError.alreadyInUse
        }
        unlink(socketPath)
    }

    private func canConnect(path: String) -> Bool {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        var addr = sockaddr_un()
        guard fillUnixAddress(&addr, path: path) else { return false }
        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return result == 0
    }

    private func bindUnix(fd: Int32, path: String) throws {
        var addr = sockaddr_un()
        guard fillUnixAddress(&addr, path: path) else {
            throw DesktopCompanionOwnerSocketError.pathTooLong
        }
        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { throw DesktopCompanionOwnerSocketError.bindFailed }
    }

    private func fillUnixAddress(_ addr: inout sockaddr_un, path: String) -> Bool {
        addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return false }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }
        return true
    }

    private func chmodPath(_ path: String, mode: mode_t) throws {
        guard chmod(path, mode) == 0 else {
            throw DesktopCompanionOwnerSocketError.chmodFailed
        }
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & 0o777) == mode else {
            throw DesktopCompanionOwnerSocketError.chmodFailed
        }
    }

    private func removeSocket(identity: SocketIdentity?) {
        guard let identity else { return }
        var st = stat()
        guard lstat(socketPath, &st) == 0 else { return }
        if (st.st_mode & S_IFMT) == S_IFSOCK, st.st_dev == identity.dev, st.st_ino == identity.ino {
            unlink(socketPath)
        }
    }

    private func unlinkOwnedSocket() {
        var st = stat()
        guard lstat(socketPath, &st) == 0 else { return }
        if (st.st_mode & S_IFMT) == S_IFSOCK, st.st_uid == getuid() {
            unlink(socketPath)
        }
    }
}

enum DesktopCompanionOwnerSocketPath {
    static let maxPathBytes = 100
    static let runtimeDirectoryName = "run"
    static let socketName = "companion.sock"

    static func defaultRuntimeRoot() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OppiDesktopCompanion", isDirectory: true)
    }

    static func socketURL(runtimeRoot: URL) -> URL {
        let preferred = runtimeRoot
            .appendingPathComponent(runtimeDirectoryName, isDirectory: true)
            .appendingPathComponent(socketName, isDirectory: false)
        if preferred.path.lengthOfBytes(using: .utf8) <= maxPathBytes {
            return preferred
        }
        return URL(fileURLWithPath: "/tmp/oppi-desktop-\(getuid())/\(socketName)")
    }

    static func ensurePrivateRuntimeDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        var st = stat()
        guard lstat(url.path, &st) == 0 else {
            throw DesktopCompanionOwnerSocketError.runtimePathNotDirectory
        }
        guard (st.st_mode & S_IFMT) == S_IFDIR else {
            throw DesktopCompanionOwnerSocketError.runtimePathNotDirectory
        }
        guard st.st_uid == getuid() else {
            throw DesktopCompanionOwnerSocketError.runtimeDirectoryNotOwned
        }
        guard chmod(url.path, 0o700) == 0 else {
            throw DesktopCompanionOwnerSocketError.chmodFailed
        }
        guard lstat(url.path, &st) == 0, (st.st_mode & 0o777) == 0o700 else {
            throw DesktopCompanionOwnerSocketError.chmodFailed
        }
    }
}

enum DesktopCompanionOwnerSocketError: Error, Equatable {
    case alreadyOwned(pid: pid_t)
    case alreadyInUse
    case runtimeDirectoryNotOwned
    case runtimePathNotDirectory
    case pathTooLong
    case bindFailed
    case listenFailed
    case chmodFailed
    case lockFailed
    case notASocket
}

private struct SocketLockRecord: Codable, Equatable {
    var pid: pid_t
    var token: String
    var processInstanceToken: String
}

private struct HeldSocketLock {
    var path: String
    var serialized: Data

    func release() {
        if let current = try? Data(contentsOf: URL(fileURLWithPath: path)), current == serialized {
            unlink(path)
        }
    }
}

private struct SocketIdentity {
    var dev: dev_t
    var ino: ino_t
}

private func isProcessRunning(_ pid: pid_t) -> Bool {
    if kill(pid, 0) == 0 { return true }
    return errno == EPERM
}
