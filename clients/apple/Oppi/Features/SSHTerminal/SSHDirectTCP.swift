import Darwin
import Foundation

/// Matches the existing fd handoff rather than introducing another NIO
/// bootstrap owner. DNS runs off-main; BlockingSocketDial bounds the caller,
/// cancellation and late-fd disposal. Nonblocking connect/poll also bounds the
/// worker's connect attempts to one shared 12-second budget across addresses.
enum SSHDirectTCP {
    static func dial(host: String, port: UInt16) async throws -> Int32 {
        try await BlockingSocketDial.run(timeout: .seconds(15)) {
            var hints = addrinfo()
            hints.ai_family = AF_UNSPEC
            hints.ai_socktype = SOCK_STREAM
            hints.ai_protocol = IPPROTO_TCP
            var result: UnsafeMutablePointer<addrinfo>?
            let lookup = getaddrinfo(host, String(port), &hints, &result)
            guard lookup == 0 else { return .failure(.dialFailed(String(cString: gai_strerror(lookup)))) }
            defer { freeaddrinfo(result) }
            let deadline = ContinuousClock.now.advanced(by: .seconds(12))
            var address = result
            var lastError = ECONNREFUSED
            while let current = address {
                address = current.pointee.ai_next
                let info = current.pointee
                let fd = socket(info.ai_family, info.ai_socktype, info.ai_protocol)
                guard fd >= 0 else { lastError = errno; continue }
                let flags = fcntl(fd, F_GETFL)
                guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
                    lastError = errno
                    close(fd)
                    continue
                }
                var connected = Darwin.connect(fd, info.ai_addr, info.ai_addrlen) == 0
                if !connected, errno == EINPROGRESS {
                    let remaining = ContinuousClock.now.duration(to: deadline)
                    let milliseconds = max(0, Int(remaining.components.seconds * 1000 + remaining.components.attoseconds / 1_000_000_000_000_000))
                    var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    if poll(&descriptor, 1, Int32(milliseconds)) > 0 {
                        var failure: Int32 = 0
                        var size = socklen_t(MemoryLayout<Int32>.size)
                        if getsockopt(fd, SOL_SOCKET, SO_ERROR, &failure, &size) == 0 {
                            connected = failure == 0
                            lastError = failure
                        } else { lastError = errno }
                    } else { lastError = ETIMEDOUT }
                } else if !connected { lastError = errno }
                if connected { return .success(fd) } // SSHPTYSession takes ownership.
                close(fd)
                if ContinuousClock.now >= deadline { break }
            }
            return .failure(.dialFailed(String(cString: strerror(lastError))))
        }
    }
}
