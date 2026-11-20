import Foundation
import Synchronization

/// Files sent to a Rex pane's machine through Rex itself (API revision 11,
/// `com.superlogical.terminal.upload_begin`), over whatever carries the
/// terminal: Tailscale or the SSH bridge, with no SSH side command. It is how
/// Rex's own apps upload a dropped file or a pasted screenshot.
///
/// Per file, `upload_begin` reserves it on the pane and returns a one-time data
/// ticket. A data socket with the `rex.data.bytes.v1` subprotocol says HELLO
/// with the ticket and gets WELCOME (`RexDataHandshake`), carries the bytes in
/// messages of at most `chunkBytes`, then one empty message, which half-closes
/// it. Once the last file of a batch has arrived, Rex types every path of the
/// batch into the pane as a paste, and only then closes each stream with 1000.
/// Any other close means nothing was typed and nothing was kept. Rex keeps the
/// files in its own uploads folder and removes them with the pane, or the
/// oldest ones when a new file needs room.
enum RexUpload {
    /// Rex's largest data message.
    static let chunkBytes = 64 * 1024
    /// From the first file's reservation to the last stream's close: as long
    /// as an upload over SSH may take.
    static let timeout: Duration = .seconds(120)
    /// The close Rex ends a stream with once the batch's paths were typed.
    static let typedCloseCode: UInt16 = 1000

    enum Failure: Error, Equatable, LocalizedError {
        /// Rex closed a file's stream with another code: nothing was typed.
        case notSaved(code: UInt16?, reason: String)

        var errorDescription: String? {
            switch self {
            case .notSaved(let code, let reason):
                let why = [code.map { "status \($0)" }, reason.isEmpty ? nil : reason].compactMap { $0 }.joined(separator: ", ")
                return why.isEmpty ? "Rex did not save the file." : "Rex did not save the file (\(why))."
            }
        }
    }

    /// `data` as the messages that carry it: whole chunks of `chunkBytes`, the
    /// rest, then the empty message that half-closes the stream.
    static func messages(_ data: Data) -> [Data] {
        stride(from: 0, to: data.count, by: chunkBytes).map {
            data.subdata(in: (data.startIndex + $0)..<(data.startIndex + min($0 + chunkBytes, data.count)))
        } + [Data()]
    }

    /// `upload_begin`'s arguments for file `index` of `count`. A lone file has
    /// no batch; several share one, so Rex types their paths together.
    static func beginArguments(name: String, size: Int, ref: UUID, batch: UUID?, index: Int, count: Int) -> [String: Any] {
        var args: [String: Any] = ["ref": "upload:\(ref.uuidString.lowercased())", "name": name, "size": size]
        if let batch {
            args["batch"] = batch.uuidString.lowercased()
            args["index"] = index
            args["count"] = count
        }
        return args
    }

    /// Sends `files` to `block` of `session` and returns once Rex typed their
    /// paths there. Throws when any file was not saved; Rex then typed none.
    static func send(
        _ files: [SSHTerminalUpload.File], to block: String, session: String,
        control: RexControl, transport: any RexTransport
    ) async throws {
        guard !files.isEmpty else { return }
        let open = OpenSockets()
        // Closing every socket ends each stream, so a Rex that stops answering
        // fails the upload instead of holding it.
        let watchdog = Task {
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            open.closeAll()
        }
        defer {
            watchdog.cancel()
            open.closeAll()
        }
        let batch = files.count > 1 ? UUID() : nil
        var streams: [AsyncStream<RexSocketEvent>.Iterator] = []
        for (index, file) in files.enumerated() {
            let answer = try await control.call("com.superlogical.terminal.upload_begin", [
                "session_id": session, "block_id": block,
                "args": beginArguments(name: file.name, size: file.data.count, ref: UUID(), batch: batch, index: index, count: files.count),
            ])
            struct Ticket: Decodable { let ticket: String }
            guard let ticket = (try? JSONDecoder().decode(Ticket.self, from: answer)).flatMap({ RexSessionConnection.base64URL($0.ticket) }),
                  ticket.count == 16 else {
                throw RexClientError.unreadable("an upload ticket")
            }
            let (events, sink) = AsyncStream.makeStream(of: RexSocketEvent.self)
            let socket = try await transport.openData(.bytes, inboundFlow: nil) { event in
                sink.yield(event)
                if case .ended = event { sink.finish() }
            }
            open.add(socket)
            var stream = events.makeAsyncIterator()
            try await socket.send(.binary(RexDataHandshake.hello(ticket: ticket)))
            try await welcome(&stream)
            for message in messages(file.data) { try await socket.send(.binary(message)) }
            streams.append(stream)
        }
        // A batch's streams close together, after its last file: each is waited
        // on only once every file was sent.
        for index in streams.indices { try await typed(&streams[index]) }
    }

    /// The handshake's answer: WELCOME, or why Rex refused the stream.
    private static func welcome(_ stream: inout AsyncStream<RexSocketEvent>.Iterator) async throws {
        while let event = await stream.next() {
            switch event {
            case .message(.binary(let bytes)):
                if case .reject(let reason) = try RexDataHandshake.answer(bytes) { throw RexDataHandshake.Failure.rejected(reason) }
                return
            case .message(.close(let code, let reason)):
                throw Failure.notSaved(code: code, reason: reason)
            case .ended(let error):
                throw error
            case .message, .writable:
                continue
            }
        }
        throw RexClientError.connectionClosed
    }

    /// The stream's close: 1000 once Rex typed the paths.
    private static func typed(_ stream: inout AsyncStream<RexSocketEvent>.Iterator) async throws {
        while let event = await stream.next() {
            switch event {
            case .message(.close(let code, let reason)):
                guard code == typedCloseCode else { throw Failure.notSaved(code: code, reason: reason) }
                return
            case .ended(let error):
                throw error
            case .message, .writable:
                continue
            }
        }
        throw RexClientError.connectionClosed
    }
}

/// The upload's sockets, closed together when it ends or times out.
private final class OpenSockets: Sendable {
    private let sockets = Mutex<[any RexSocket]>([])

    func add(_ socket: any RexSocket) { sockets.withLock { $0.append(socket) } }

    func closeAll() { sockets.withLock { $0 }.forEach { $0.close() } }
}
