import Foundation
import ImageIO
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import Oppi

/// The animation rule for image icons: an icon view plays an animated image only
/// when it was made to (`animatesImage`, the Agent page and the icon picker), and
/// stops when it leaves its window. Everywhere else it draws the first frame.
@Suite("Icon image animation")
@MainActor
struct IconChoiceUIViewAnimationTests {
    private enum Swatch: Hashable { case red, green, blue, other }

    @Test func onlyAnAnimatingViewPlaysAndItStopsWhenItLeavesItsWindow() async throws {
        let gif = try Self.gif(frames: [.systemRed, .systemGreen, .systemBlue])
        let window = makeTestWindow(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        window.isHidden = false
        defer { hideTestWindow(window) }

        let still = IconChoiceUIView(size: 48, frameSize: 64)
        let playing = IconChoiceUIView(size: 48, frameSize: 64, animatesImage: true)
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

        let stillSeen = try await swatches(of: still, for: .milliseconds(900))
        let playingSeen = try await swatches(of: playing, for: .milliseconds(900))
        #expect(stillSeen == [.red], "the default view draws the first frame and nothing else")
        #expect(playingSeen.isSuperset(of: [.red, .green, .blue]), "the animating view plays every frame: \(playingSeen)")

        playing.removeFromSuperview()
        try await Task.sleep(for: .milliseconds(150))
        let afterRemoval = try await swatches(of: playing, for: .milliseconds(600))
        #expect(afterRemoval.count == 1, "a view out of its window stops playing: \(afterRemoval)")
    }

    /// The colours `view` shows, sampled every 50 ms for `duration`.
    private func swatches(of view: UIView, for duration: Duration) async throws -> Set<Swatch> {
        var seen: Set<Swatch> = []
        let end = ContinuousClock.now + duration
        while ContinuousClock.now < end {
            seen.insert(Self.centreSwatch(of: view))
            try await Task.sleep(for: .milliseconds(50))
        }
        return seen
    }

    private static func centreSwatch(of view: UIView) -> Swatch {
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
    private static func gif(frames colors: [UIColor]) throws -> Data {
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
}
