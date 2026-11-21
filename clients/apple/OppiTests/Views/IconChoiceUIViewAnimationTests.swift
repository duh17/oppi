import Foundation
import ImageIO
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import Oppi

/// The animation rule for image icons: an icon view plays an animated image only
/// when it was made to (`animates`, the Agent page and the icon picker), and
/// stops when it leaves its window. Everywhere else it draws the first frame.
@Suite("Icon image animation")
@MainActor
struct IconChoiceUIViewAnimationTests {

    @Test func onlyAnAnimatingViewPlaysAndItStopsWhenItLeavesItsWindow() async throws {
        let gif = try animatedGIFFrames([.systemRed, .systemGreen, .systemBlue])
        let window = makeTestWindow(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        window.isHidden = false
        defer { hideTestWindow(window) }

        let still = IconChoiceUIView(frameSize: 64)
        let playing = IconChoiceUIView(frameSize: 64, animates: true)
        for (index, view) in [still, playing].enumerated() {
            view.translatesAutoresizingMaskIntoConstraints = false
            window.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: window.leadingAnchor, constant: CGFloat(index) * 100),
                view.topAnchor.constraint(equalTo: window.topAnchor),
            ])
            view.apply(.importedImage(gif))
        }
        window.layoutIfNeeded()
        #expect(still.bounds.width == 64 && playing.bounds.width == 64)

        let stillSeen = try await centreSwatches(of: still, for: .milliseconds(900))
        let playingSeen = try await centreSwatches(of: playing, for: .milliseconds(900))
        #expect(stillSeen == [.red], "the default view draws the first frame and nothing else")
        #expect(playingSeen.isSuperset(of: [.red, .green, .blue]), "the animating view plays every frame: \(playingSeen)")

        playing.removeFromSuperview()
        try await Task.sleep(for: .milliseconds(150))
        let afterRemoval = try await centreSwatches(of: playing, for: .milliseconds(600))
        #expect(afterRemoval.count == 1, "a view out of its window stops playing: \(afterRemoval)")
    }
}

private enum Swatch: Hashable { case red, green, blue, other }

/// The colours `view` shows, sampled every 50 ms for `duration`. Drawing a live
/// window's layers must happen on the main actor, or Auto Layout asserts.
@MainActor
private func centreSwatches(of view: UIView, for duration: Duration) async throws -> Set<Swatch> {
    var seen: Set<Swatch> = []
    let end = ContinuousClock.now + duration
    while ContinuousClock.now < end {
        seen.insert(centreSwatch(of: view))
        try await Task.sleep(for: .milliseconds(50))
    }
    return seen
}

@MainActor
private func centreSwatch(of view: UIView) -> Swatch {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let image = UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { context in
        view.layer.render(in: context.cgContext)
    }
    let pixel = image.cgImage.flatMap { $0.cropping(to: CGRect(x: $0.width / 2, y: $0.height / 2, width: 1, height: 1)) }
    var rgba = [UInt8](repeating: 0, count: 4)
    rgba.withUnsafeMutableBytes { storage in
        guard let pixel, let context = CGContext(
            data: storage.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    }
    let (r, g, b) = (Int(rgba[0]), Int(rgba[1]), Int(rgba[2]))
    if r > 180, g < 120, b < 120 { return .red }
    if g > 150, r < 120, b < 150 { return .green }
    if b > 180, r < 120 { return .blue }
    return .other
}

/// A looping GIF of solid frames, 100 ms each.
@MainActor
private func animatedGIFFrames(_ colors: [UIColor]) throws -> Data {
    let output = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(
        output, UTType.gif.identifier as CFString, colors.count, nil
    ))
    CGImageDestinationSetProperties(destination, [
        kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
    ] as CFDictionary)
    let frameProperties = [
        kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1],
    ] as CFDictionary
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    for color in colors {
        let frame = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32), format: format).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }
        CGImageDestinationAddImage(destination, try #require(frame.cgImage), frameProperties)
    }
    #expect(CGImageDestinationFinalize(destination))
    return output as Data
}

/// A burst plays the icon briefly and then rests on its still drawing: an
/// animated image's frames for `burstDuration`, a symbol's effect once. A view
/// outside a window, and one that already animates, do not burst.
@Suite("Icon burst")
@MainActor
struct IconBurstTests {
    /// The image views the icon shows: its still drawing, then the one an
    /// effect or an animated image plays in.
    private func liveLayers(of view: IconChoiceUIView) -> Int {
        view.subviews.compactMap { $0 as? UIImageView }.filter { !$0.isHidden }.count
    }

    private let windowFrame = CGRect(x: 0, y: 0, width: 200, height: 200)

    private func makeWindow() -> UIWindow {
        let window = makeTestWindow(frame: windowFrame)
        window.isHidden = false
        return window
    }

    private func add(_ view: IconChoiceUIView, to window: UIWindow) {
        view.translatesAutoresizingMaskIntoConstraints = false
        window.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: window.leadingAnchor),
            view.topAnchor.constraint(equalTo: window.topAnchor),
        ])
        window.layoutIfNeeded()
    }

    @Test func anAnimatedImageBurstsThenRestsOnItsFirstFrame() async throws {
        let gif = try animatedGIFFrames([.systemRed, .systemGreen, .systemBlue])
        let window = makeWindow()
        defer { hideTestWindow(window) }
        let view = IconChoiceUIView(frameSize: 64)
        add(view, to: window)
        view.apply(.importedImage(gif))

        let before = try await centreSwatches(of: view, for: .milliseconds(200))
        #expect(before == [.red], "an icon that is asked to burst draws its first frame first")

        view.playBurst()
        let during = try await centreSwatches(of: view, for: .milliseconds(1_200))
        #expect(during.isSuperset(of: [.red, .green, .blue]), "the burst plays the frames: \(during)")

        try await Task.sleep(for: IconChoiceUIView.burstDuration)
        let after = try await centreSwatches(of: view, for: .milliseconds(600))
        #expect(after == [.red], "the burst ends on the first frame: \(after)")
        #expect(liveLayers(of: view) == 1, "the icon is back on its still drawing")
    }

    @Test func aSymbolEffectRunsOnceThenRestsOnItsDrawing() async throws {
        let window = makeWindow()
        defer { hideTestWindow(window) }
        let view = IconChoiceUIView(frameSize: 64)
        add(view, to: window)
        view.apply(.choice(.symbol("star.fill", effect: .bounce), purpose: .agent, sandbox: false))
        #expect(liveLayers(of: view) == 1, "a symbol effect does not play on its own")

        view.playBurst()
        #expect(liveLayers(of: view) == 2, "the burst runs the effect over the tile")

        try await Task.sleep(for: IconChoiceUIView.burstDuration + .milliseconds(300))
        #expect(liveLayers(of: view) == 1, "the icon rests on its still drawing again")
    }

    @Test func aBurstOffScreenPlaysNothing() {
        let view = IconChoiceUIView(frameSize: 64)
        view.apply(.choice(.symbol("star.fill", effect: .bounce), purpose: .agent, sandbox: false))

        view.playBurst()
        #expect(liveLayers(of: view) == 1, "a row that is not on screen plays nothing")
    }

    @Test func stoppingOrClearingABurstLeavesTheStillDrawing() {
        let window = makeWindow()
        defer { hideTestWindow(window) }
        let view = IconChoiceUIView(frameSize: 64)
        add(view, to: window)
        view.apply(.choice(.symbol("star.fill", effect: .bounce), purpose: .agent, sandbox: false))

        view.playBurst()
        #expect(liveLayers(of: view) == 2)
        view.stopBurst()
        #expect(liveLayers(of: view) == 1, "a stopped burst rests")

        view.playBurst()
        #expect(liveLayers(of: view) == 2)
        view.clear()
        #expect(liveLayers(of: view) == 1, "a cleared view plays nothing")
    }

    @Test func anAnimatingViewIgnoresTheBurst() {
        let window = makeWindow()
        defer { hideTestWindow(window) }
        let view = IconChoiceUIView(frameSize: 64, animates: true)
        add(view, to: window)
        view.apply(.choice(.symbol("star.fill", effect: .bounce), purpose: .agent, sandbox: false))

        #expect(liveLayers(of: view) == 2, "the icon's own page already plays it")
        view.playBurst()
        #expect(liveLayers(of: view) == 2)
    }
}
