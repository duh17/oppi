#if DEBUG
import AVFoundation
import Network
import UIKit

/// `SCREENSHOT_SCREEN=file-viewer-video`: the file viewer on one fixture video,
/// portrait (9:16) by default or landscape (16:9) with `SCREENSHOT_VIDEO_FIXTURE=landscape`
/// (the `SCREENSHOT_` prefix is what the screenshot dump forwards to the app).
/// The clip is drawn and encoded at launch, and a loopback HTTP server hands it
/// to the app's own media loader with range requests, so the viewer takes the
/// real path from `APIClient` to `AVPlayer`.
final class FileViewerVideoPreviewController: PreviewRootController {
    init() {
        let portrait = ProcessInfo.processInfo.environment["SCREENSHOT_VIDEO_FIXTURE"] != "landscape"
        let server = FixtureVideoServer(clip: FixtureVideoClip.encode(portrait: portrait))
        let root = AppRootEnvironment.preview(coordinator: ConnectionCoordinator(serverStore: ServerStore()))
        let client = APIClient(
            baseURL: URL(string: "http://127.0.0.1:\(server.port)") ?? URL(fileURLWithPath: "/"),
            token: "preview-token"
        )
        let name = portrait ? "portrait.mp4" : "landscape.mp4"
        super.init(
            root: root,
            themeStore: root.themeStore,
            content: PreviewHost.screenStack(root: root) {
                FileViewerViewController(
                    configuration: .init(workspaceId: "preview-video", filePath: "clips/\(name)", fileName: name),
                    services: .init(apiClient: client)
                )
            }
        )
        self.server = server
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Held for the screen's life: the listener stops with it.
    private var server: FixtureVideoServer?
}

/// A three-second H.264 clip with a labelled frame, so a capture shows the
/// picture's own edges and a letterbox as a different color.
enum FixtureVideoClip {
    static func encode(portrait: Bool) -> Task<Data, Error> {
        Task.detached {
            let size = portrait ? CGSize(width: 576, height: 1024) : CGSize(width: 1024, height: 576)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("file-viewer-video-\(UUID().uuidString).mp4")
            defer { try? FileManager.default.removeItem(at: url) }
            let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: size.width,
                AVVideoHeightKey: size.height,
            ])
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: size.width,
                    kCVPixelBufferHeightKey as String: size.height,
                ]
            )
            writer.add(input)
            writer.startWriting()
            writer.startSession(atSourceTime: .zero)
            for frame in 0..<30 {
                while !input.isReadyForMoreMediaData { await Task.yield() }
                guard let buffer = drawFrame(size: size, portrait: portrait, index: frame, pool: adaptor.pixelBufferPool) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10))
            }
            input.markAsFinished()
            await writer.finishWriting()
            if let error = writer.error { throw error }
            return try Data(contentsOf: url)
        }
    }

    private static func drawFrame(size: CGSize, portrait: Bool, index: Int, pool: CVPixelBufferPool?) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        guard let pool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        let colors = [UIColor.systemTeal.cgColor, UIColor.systemIndigo.cgColor] as CFArray
        if let gradient = CGGradient(colorsSpace: nil, colors: colors, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
        }
        context.setStrokeColor(UIColor.white.cgColor)
        context.setLineWidth(12)
        context.stroke(CGRect(origin: .zero, size: size).insetBy(dx: 6, dy: 6))
        // A marker that moves, so the frames differ.
        context.setFillColor(UIColor.white.cgColor)
        context.fillEllipse(in: CGRect(x: 40 + CGFloat(index) * 8, y: size.height / 2 - 30, width: 60, height: 60))
        UIGraphicsPushContext(context)
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        (portrait ? "PORTRAIT 9:16" : "LANDSCAPE 16:9").draw(
            at: CGPoint(x: 40, y: 40),
            withAttributes: [.font: UIFont.boldSystemFont(ofSize: 56), .foregroundColor: UIColor.white]
        )
        UIGraphicsPopContext()
        return buffer
    }
}

/// Serves the clip on a loopback port for every path except the viewer's
/// metadata and caption lookups, which are 404. Honors `Range`, which
/// `AVAssetResourceLoader` needs.
private final class FixtureVideoServer: @unchecked Sendable {
    private let listener: NWListener
    private let clip: Task<Data, Error>
    let port: UInt16

    init(clip: Task<Data, Error>) {
        self.clip = clip
        // The app builds its API client before the listener is ready, so the
        // port is chosen first.
        let probe = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = bind(probe, $0, length)
                _ = getsockname(probe, $0, &length)
            }
        }
        port = UInt16(bigEndian: address.sin_port)
        close(probe)
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        guard let listener = try? NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port) ?? .any) else {
            preconditionFailure("fixture video server could not listen on \(port)")
        }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener.start(queue: .global(qos: .userInitiated))
    }

    deinit { listener.cancel() }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [clip] data, _, _, _ in
            guard let data, let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }
            Task {
                let target = request.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                let isHead = request.hasPrefix("HEAD")
                guard target.contains(".mp4"), !target.contains("media-info"),
                      let video = try? await clip.value else {
                    Self.send(connection, status: "404 Not Found", headers: [:], body: Data())
                    return
                }
                var start = 0
                var end = video.count - 1
                var status = "200 OK"
                var headers = ["Content-Type": "video/mp4", "Accept-Ranges": "bytes"]
                if let line = request.split(separator: "\r\n").first(where: { $0.lowercased().hasPrefix("range:") }),
                   let spec = line.split(separator: "=").last {
                    let parts = spec.split(separator: "-", omittingEmptySubsequences: false)
                    start = min(Int(parts.first ?? "") ?? 0, video.count - 1)
                    if parts.count > 1, let last = Int(parts[1]) { end = min(last, video.count - 1) }
                    status = "206 Partial Content"
                    headers["Content-Range"] = "bytes \(start)-\(end)/\(video.count)"
                }
                let body = video.subdata(in: start..<(end + 1))
                headers["Content-Length"] = String(body.count)
                Self.send(connection, status: status, headers: headers, body: isHead ? Data() : body)
            }
        }
    }

    private static func send(_ connection: NWConnection, status: String, headers: [String: String], body: Data) {
        var head = "HTTP/1.1 \(status)\r\nConnection: close\r\n"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }
}
#endif
