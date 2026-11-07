import CoreGraphics
import Testing
@testable import Oppi

@Suite("Media aspect fit")
struct ImageViewportAspectFitTests {
    private let box = CGSize(width: 1000, height: 600)

    private func matches(_ size: CGSize, _ width: CGFloat, _ height: CGFloat) -> Bool {
        abs(size.width - width) < 0.001 && abs(size.height - height) < 0.001
    }

    @Test("a landscape video fills the box's width and a portrait one its height")
    func fitsTheLimitingEdge() {
        let landscape = ImageViewportSizing.aspectFit(contentSize: CGSize(width: 1920, height: 1080), in: box)
        #expect(matches(landscape, 1000, 562.5), "\(landscape)")

        let portrait = ImageViewportSizing.aspectFit(contentSize: CGSize(width: 1080, height: 1920), in: box)
        #expect(matches(portrait, 337.5, 600), "\(portrait)")
    }

    @Test("a square video is a square inside the shorter edge")
    func square() {
        let size = ImageViewportSizing.aspectFit(contentSize: CGSize(width: 500, height: 500), in: box)
        #expect(matches(size, 600, 600), "\(size)")
    }

    @Test("a missing, zero, or absurd size uses the fallback ratio until the real one arrives")
    func fallback() {
        for content in [nil, CGSize.zero, CGSize(width: 0, height: 480), CGSize(width: CGFloat.nan, height: 480),
                        CGSize(width: 1, height: 10_000)] {
            let size = ImageViewportSizing.aspectFit(contentSize: content, in: box)
            #expect(matches(size, 1000, 562.5), "\(String(describing: content)) gave \(size)")
        }
        let custom = ImageViewportSizing.aspectFit(contentSize: nil, in: box, fallbackAspectRatio: 1)
        #expect(matches(custom, 600, 600), "\(custom)")
    }

    @Test("a box with no room has no size")
    func degenerateBox() {
        #expect(ImageViewportSizing.aspectFit(contentSize: nil, in: .zero) == .zero)
        #expect(ImageViewportSizing.aspectFit(contentSize: nil, in: CGSize(width: -5, height: 300)) == .zero)
        #expect(ImageViewportSizing.aspectFit(contentSize: nil, in: CGSize(width: 300, height: CGFloat.infinity)) == .zero)
    }

    @Test("a tall, thin video keeps the minimum width for its controls, never past the box")
    func minimumWidth() {
        let thin = CGSize(width: 100, height: 2_000)
        let natural = ImageViewportSizing.aspectFit(contentSize: thin, in: box)
        #expect(natural.width < 100)
        let kept = ImageViewportSizing.aspectFit(contentSize: thin, in: box, minimumWidth: 240)
        #expect(kept.width == 240)
        #expect(abs(kept.height - natural.height) < 0.001, "the height still follows the picture; the player letterboxes")
        let narrowBox = ImageViewportSizing.aspectFit(
            contentSize: thin, in: CGSize(width: 200, height: 600), minimumWidth: 240
        )
        #expect(narrowBox.width == 200)
    }
}
