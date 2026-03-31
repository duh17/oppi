import UIKit

/// Progressively reveals new characters in a UITextView during streaming.
///
/// Instead of showing all coalesced text at once (chunky 33ms jumps), this
/// hides new characters and reveals them over several display frames, producing
/// a smooth typewriter effect.
///
/// Mechanism:
/// 1. After the full attributed text is set (layout computed for full height),
///    the unrevealed portion gets `.foregroundColor = .clear`.
/// 2. A `CADisplayLink` fires at screen refresh rate (up to 120Hz ProMotion).
/// 3. Each frame, a batch of characters gets their original foreground color
///    restored from the saved normalized text.
/// 4. When all characters are visible or streaming ends, the display link stops.
///
/// Battery: the display link only runs while characters are being revealed.
/// Between coalescer flushes with no new text, it's idle (zero cost).
@MainActor
final class StreamingTextRevealer {

    // MARK: - State

    /// The text view currently being revealed.
    private weak var textView: UITextView?
    /// The full normalized attributed text (source of truth for per-character colors).
    private var originalText: NSAttributedString?
    /// Number of characters currently visible.
    private var visibleCount: Int = 0
    /// Total characters in the text view.
    private var totalCount: Int = 0

    /// Visible-character count tracked across overlapping reveal calls.
    /// This lets callers continue a reveal from the true on-screen boundary
    /// instead of assuming the previous batch already finished animating.
    var currentVisibleCount: Int { visibleCount }
    /// Characters to reveal per display frame.
    private var charsPerFrame: Double = 3.0
    /// Fractional accumulator for sub-character reveal rates.
    private var fractionalChars: Double = 0.0

    private var displayLink: CADisplayLink?

    // MARK: - Configuration

    /// Target duration to reveal each batch of new characters.
    /// Slightly longer than the coalescer interval (33ms) so reveal animation
    /// visibly overlaps with the next flush — producing a gentle, continuous
    /// appear effect similar to ChatGPT's streaming reveal.
    private let revealDuration: Double = 0.060 // 60ms (coalescer is 33ms)

    /// Minimum characters to reveal per frame (avoids imperceptible single-char reveals).
    private let minCharsPerFrame: Double = 1.0

    // MARK: - Public API

    /// Begin or continue revealing text in the given text view.
    ///
    /// Call after setting `textView.attributedText` with the full normalized text.
    /// Characters beyond `previousVisibleCount` will be hidden and progressively revealed.
    ///
    /// - Parameters:
    ///   - textView: The text view containing the full text.
    ///   - normalizedText: The original NSAttributedString (for restoring per-character colors).
    ///   - previousVisibleCount: How many characters were already visible before this update.
    func reveal(
        in textView: UITextView,
        normalizedText: NSAttributedString,
        previousVisibleCount: Int
    ) {
        let total = normalizedText.length
        guard total > previousVisibleCount else { return }

        self.textView = textView
        // Snapshot: normalizedText may be a mutable NSMutableAttributedString
        // that the caller continues to mutate. Storing a reference caused
        // NSRangeException crashes when the display link tick enumerated
        // attributes on a string whose storage was concurrently modified.
        self.originalText = NSAttributedString(attributedString: normalizedText)
        self.visibleCount = previousVisibleCount
        self.totalCount = total

        // Hide the unrevealed portion.
        let hiddenRange = NSRange(location: previousVisibleCount, length: total - previousVisibleCount)
        textView.textStorage.addAttribute(.foregroundColor, value: UIColor.clear, range: hiddenRange)

        // Calculate reveal speed: finish before next coalescer flush.
        let newChars = Double(total - previousVisibleCount)
        let screenRefreshRate = Double(UIScreen.main.maximumFramesPerSecond)
        let framesAvailable = max(1.0, revealDuration * screenRefreshRate)
        charsPerFrame = max(minCharsPerFrame, newChars / framesAvailable)
        fractionalChars = 0.0

        startDisplayLink()
    }

    /// Instantly reveal all remaining characters and stop the animation.
    /// Call when streaming ends or the cell is recycled.
    func finishImmediately() {
        guard let textView, let originalText, visibleCount < totalCount else {
            stopDisplayLink()
            return
        }

        let remainingRange = NSRange(location: visibleCount, length: totalCount - visibleCount)
        restoreOriginalColors(in: remainingRange, textView: textView, original: originalText)
        visibleCount = totalCount
        stopDisplayLink()
    }

    /// Mark the current text as already fully visible without starting an animation.
    /// Use this after a full replacement / initial render so overlapping future
    /// streaming updates can start from the real visible boundary.
    func setFullyVisibleCount(_ count: Int) {
        visibleCount = count
        totalCount = count
        stopDisplayLink()
    }

    /// Stop and reset all state. Call when the view is cleared or recycled.
    func reset() {
        stopDisplayLink()
        textView = nil
        originalText = nil
        visibleCount = 0
        totalCount = 0
    }

    // MARK: - Display Link

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        // Prefer high frame rate on ProMotion displays for smooth reveal.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func tick(_: CADisplayLink) {
        guard let textView, let originalText, visibleCount < totalCount else {
            stopDisplayLink()
            return
        }

        // If textStorage or originalText was mutated/replaced externally,
        // bail out to avoid out-of-bounds access.
        let storageLength = textView.textStorage.length
        let originalLength = originalText.length
        guard storageLength >= totalCount, originalLength >= totalCount else {
            visibleCount = min(storageLength, originalLength)
            totalCount = visibleCount
            stopDisplayLink()
            return
        }

        fractionalChars += charsPerFrame
        let charsToReveal = Int(fractionalChars)
        guard charsToReveal > 0 else { return }
        fractionalChars -= Double(charsToReveal)

        let nextVisible = min(totalCount, visibleCount + charsToReveal)
        let revealRange = NSRange(location: visibleCount, length: nextVisible - visibleCount)
        restoreOriginalColors(in: revealRange, textView: textView, original: originalText)
        visibleCount = nextVisible

        if visibleCount >= totalCount {
            stopDisplayLink()
        }
    }

    // MARK: - Helpers

    /// Restore the original per-character foreground colors in the given range.
    private func restoreOriginalColors(
        in range: NSRange,
        textView: UITextView,
        original: NSAttributedString
    ) {
        let storageLength = textView.textStorage.length
        let originalLength = original.length
        let rangeEnd = range.location + range.length
        guard range.length > 0,
              rangeEnd <= originalLength,
              rangeEnd <= storageLength else { return }

        // Clamp enumeration to the validated original length as defense-in-depth.
        // The guard above should be sufficient, but NSMutableAttributedString
        // internals (NSMutableRLEArray) throw NSRangeException on stale ranges
        // and Swift cannot catch Objective-C exceptions.
        let safeEnd = min(rangeEnd, originalLength)
        let safeRange = NSRange(location: range.location, length: safeEnd - range.location)
        guard safeRange.length > 0 else { return }

        original.enumerateAttribute(.foregroundColor, in: safeRange) { color, attrRange, stop in
            guard attrRange.location + attrRange.length <= storageLength else {
                stop.pointee = true
                return
            }
            if let color {
                textView.textStorage.addAttribute(.foregroundColor, value: color, range: attrRange)
            }
        }
    }
}
