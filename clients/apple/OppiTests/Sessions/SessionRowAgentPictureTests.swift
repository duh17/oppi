import Foundation
import Testing
import UIKit
@testable import Oppi

/// A session row's saved-Agent picture. The row draws the person fallback only
/// until the Agent's bytes are on the device; bytes that arrive after the row
/// was configured are drawn without the row being configured again, the way a
/// list draws a row once and its artwork arrives a moment later.
@MainActor
@Suite("Session row Agent picture")
struct SessionRowAgentPictureTests {
    private let assetId = "ia_" + String(repeating: "R", count: 43)

    private func session(agentIcon: IconChoice) -> Session {
        var session = Session(
            id: "agent-picture",
            workspaceId: "ws",
            workspaceName: "oppi",
            name: "Iris health",
            status: .ready,
            createdAt: Date(timeIntervalSince1970: 1_000),
            lastActivity: Date(timeIntervalSince1970: 1_000),
            model: "anthropic/claude-opus-5-5",
            messageCount: 4,
            tokens: TokenUsage(input: 8_000, output: 1_200),
            cost: 0.1
        )
        session.launch = SessionLaunchMetadata(agentId: "iris", agentIcon: agentIcon)
        session.programStatus = ProgramStatus(state: .done, since: Date(timeIntervalSince1970: 1_000))
        return session
    }

    private func makeRow(agentIcon: IconChoice, cache: IconAssetCache?, in window: UIWindow) -> SessionRowView {
        let row = SessionRowView(combinesAccessibility: true)
        row.frame = CGRect(x: 0, y: 0, width: 430, height: 60)
        window.addSubview(row)
        row.apply(
            SessionRowView.Content(presentation: SessionRowPresentationBuilder.make(session: session(agentIcon: agentIcon))),
            display: .standard,
            themeID: .dark,
            iconAssetCache: cache
        )
        window.layoutIfNeeded()
        return row
    }

    private func descendants<T: UIView>(of root: UIView, _ type: T.Type) -> [T] {
        root.subviews.flatMap { ([$0 as? T].compactMap { $0 }) + descendants(of: $0, type) }
    }

    private func badge(in row: SessionRowView) throws -> SessionGridBadgeView {
        try #require(descendants(of: row, SessionGridBadgeView.self).first)
    }

    /// The colour the row's identity circle shows where its artwork draws.
    private func drawnCentre(of badge: SessionGridBadgeView) -> (r: Int, g: Int, b: Int) {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: badge.bounds, format: format).image { context in
            badge.layer.render(in: context.cgContext)
        }
        let centre = CGPoint(x: badge.bounds.midX, y: badge.bounds.midY)
        return image.pixel(at: centre)
    }

    @Test func theRowsCircleShowsThePictureWhenItsBytesArriveAfterItWasConfigured() async throws {
        let bytes = IconBytesArrival()
        let cache = IconAssetCache(
            fetch: { _ in try await bytes.arrived() },
            decode: { _, _ in (Self.solid(.systemPink, side: 8), NSObject()) }
        )
        let window = makeTestWindow(frame: CGRect(x: 0, y: 0, width: 430, height: 300))
        window.isHidden = false
        defer { hideTestWindow(window) }

        let row = makeRow(agentIcon: .image(assetId: assetId), cache: cache, in: window)
        let badge = try badge(in: row)
        let fallback = drawnCentre(of: badge)
        #expect(!(fallback.r > 180 && fallback.b < 160), "the row draws the person fallback first: \(fallback)")

        // The Agent's bytes reach the device after the row was already drawn.
        await bytes.push(Data([1, 2, 3]))

        let picture = try await drawnCentre(onceItIsThePictureIn: { badge })
        #expect(picture.r > 180 && picture.b < 160, "the arriving picture replaces the fallback: \(picture)")
    }

    /// The list's own configure: the row is drawn while the connection has no
    /// icon cache yet (a launch that lists cached sessions before it connects),
    /// and the cache arrives while the same sessions are on screen.
    @Test func theListsRowDrawsThePictureWhenTheIconsCacheArrivesAfterItsFirstConfigure() async throws {
        let cache = IconAssetCache(
            fetch: { _ in Data([1, 2, 3]) },
            decode: { _, _ in (Self.solid(.systemPink, side: 8), NSObject()) }
        )
        var provider: IconAssetCache?
        let list = SessionListCollection<Int, String, Int, Int>(
            root: makeTestAppRoot(),
            appearance: .plain,
            actions: SessionListRowActions(
                open: { _ in }, toggleThread: { _ in }, toggleStoppedMembers: { _ in },
                stop: { _ in }, resume: { _ in }, delete: { _ in nil }, lockTarget: { _ in nil }
            ),
            iconAssetCache: { provider },
            configureRow: { _, _ in },
            onToggle: { _ in }
        )
        let window = makeTestWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 800))
        let controller = UIViewController()
        list.collectionView.frame = window.bounds
        controller.view.addSubview(list.collectionView)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { hideTestWindow(window) }

        let entry = SessionListEntries.threads(listed: [session(agentIcon: .image(assetId: assetId))], loaded: []).first
        let listed = try #require(entry)
        var snapshot = SessionListCollection<Int, String, Int, Int>.Snapshot()
        snapshot.appendSection(0)
        snapshot.append(sessions: [listed], to: 0, item: { $0 }) { entry in
            SessionListRowContent(
                entry: entry,
                presentation: SessionRowPresentationBuilder.make(session: entry.session, workspaceContext: "oppi"),
                statuses: [:]
            )
        }
        list.apply(snapshot)
        settle(window)

        let fallback = try drawnPictureCentre(in: list, window: window)
        #expect(!(fallback.r > 180 && fallback.b < 160), "the row draws the person fallback first: \(fallback)")

        // The connection installs its cache, and the list is applied again with
        // the same sessions: only the icons' source changed.
        provider = cache
        list.apply(snapshot)
        settle(window)

        let picture = try await drawnCentre(
            onceItIsThePictureIn: { try? drawnBadge(in: list, window: window) }
        )
        #expect(picture.r > 180 && picture.b < 160, "the row draws the picture once its cache arrives: \(picture)")
    }

    private func settle(_ window: UIWindow) {
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        window.layoutIfNeeded()
    }

    /// The list's only row's identity circle, as it is now.
    private func drawnBadge(
        in list: SessionListCollection<Int, String, Int, Int>,
        window: UIWindow
    ) throws -> SessionGridBadgeView {
        settle(window)
        let cell = try #require(list.collectionView.cellForItem(at: IndexPath(item: 0, section: 0)))
        return try #require(descendants(of: cell, SessionGridBadgeView.self).first)
    }

    /// The colour the list's only row shows on its identity circle.
    private func drawnPictureCentre(
        in list: SessionListCollection<Int, String, Int, Int>,
        window: UIWindow
    ) throws -> (r: Int, g: Int, b: Int) {
        drawnCentre(of: try drawnBadge(in: list, window: window))
    }

    /// Samples `badge` until it draws the Agent's picture, or the wait runs out:
    /// another suite's icon load can bump the owner's announcement, so the
    /// pixels are what this waits on.
    private func drawnCentre(
        onceItIsThePictureIn badge: @escaping @MainActor () -> SessionGridBadgeView?,
        timeout: Duration = .seconds(3)
    ) async throws -> (r: Int, g: Int, b: Int) {
        let end = ContinuousClock.now + timeout
        var seen = (r: 0, g: 0, b: 0)
        while ContinuousClock.now < end {
            if let view = badge() {
                seen = drawnCentre(of: view)
                if seen.r > 180 && seen.b < 160 { return seen }
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        return seen
    }

    private static func solid(_ colour: UIColor, side: CGFloat) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { context in
            colour.setFill()
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        }
    }
}

/// The Agent's bytes, held until the test says they reached the device, so a
/// row's first configure draws while they are still missing.
private actor IconBytesArrival {
    private var bytes: Data?
    private var waiters: [CheckedContinuation<Data, Error>] = []

    func arrived() async throws -> Data {
        if let bytes { return bytes }
        return try await withCheckedThrowingContinuation { waiters.append($0) }
    }

    func push(_ data: Data) {
        bytes = data
        waiters.forEach { $0.resume(returning: data) }
        waiters = []
    }
}

private extension UIImage {
    /// The colour of the pixel at `point`, in the image's own points.
    func pixel(at point: CGPoint) -> (r: Int, g: Int, b: Int) {
        let x = Int(point.x / size.width * CGFloat(cgImage?.width ?? 1))
        let y = Int(point.y / size.height * CGFloat(cgImage?.height ?? 1))
        guard let cgImage,
              let cropped = cgImage.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else { return (0, 0, 0) }
        var rgba = [UInt8](repeating: 0, count: 4)
        rgba.withUnsafeMutableBytes { storage in
            guard let context = CGContext(
                data: storage.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return (Int(rgba[0]), Int(rgba[1]), Int(rgba[2]))
    }
}
