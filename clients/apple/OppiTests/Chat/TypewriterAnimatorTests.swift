import Foundation
import Testing
@testable import Oppi

@Suite("TypewriterAnimator")
@MainActor
struct TypewriterAnimatorTests {

    // MARK: - Basic Behavior

    @Test func initialStateIsEmpty() {
        let animator = TypewriterAnimator()
        #expect(animator.displayText.isEmpty)
        #expect(!animator.isAnimating)
    }

    @Test func firstUpdateStartsAnimation() {
        let animator = TypewriterAnimator()
        animator.update(fullText: "Hello world")
        #expect(animator.isAnimating)
        #expect(animator.displayText.isEmpty, "Delta is the full string, so display starts empty")
    }

    @Test func commitSnapsToTarget() {
        let animator = TypewriterAnimator()
        animator.update(fullText: "Hello world")
        #expect(animator.isAnimating)

        animator.commitCurrentAnimation()
        #expect(animator.displayText == "Hello world")
        #expect(!animator.isAnimating)
    }

    @Test func resetClearsEverything() {
        let animator = TypewriterAnimator()
        animator.update(fullText: "Hello world")
        animator.commitCurrentAnimation()

        animator.reset()
        #expect(animator.displayText.isEmpty)
        #expect(!animator.isAnimating)
    }

    // MARK: - Delta Computation

    @Test func smallSecondUpdateSnapsDelta() {
        let animator = TypewriterAnimator()

        animator.update(fullText: "Hello")
        animator.commitCurrentAnimation()
        #expect(animator.displayText == "Hello")

        // Second update adds only one short word — should snap to keep dictation immediate.
        animator.update(fullText: "Hello world")
        #expect(!animator.isAnimating)
        #expect(animator.displayText == "Hello world")
    }

    @Test func largeSecondUpdateAnimatesOnlyDelta() {
        let animator = TypewriterAnimator()

        animator.update(fullText: "Hello")
        animator.commitCurrentAnimation()

        let updated = "Hello beautiful world"
        animator.update(fullText: updated)
        #expect(animator.isAnimating)
        #expect(animator.displayText == "Hello")

        animator.commitCurrentAnimation()
        #expect(animator.displayText == updated)
    }

    @Test func shorterTextSnapsImmediately() {
        let animator = TypewriterAnimator()

        animator.update(fullText: "Hello world")
        animator.commitCurrentAnimation()

        // Correction: shorter text
        animator.update(fullText: "Hello")
        #expect(!animator.isAnimating, "Shorter text should snap, not animate")
        #expect(animator.displayText == "Hello")
    }

    // MARK: - Correction Handling

    @Test func correctionSnapsToOldLength() {
        let animator = TypewriterAnimator()

        animator.update(fullText: "hello im testing")
        animator.commitCurrentAnimation()

        // Batch correction changes capitalization + adds text
        animator.update(fullText: "Hello, I'm testing this.")
        // Should snap corrected portion (up to old length), animate only new chars
        let display = animator.displayText
        #expect(display.count >= "hello im testing".count,
                "Correction should snap to at least old text length, got: \(display)")
    }

    @Test func correctionWithSameLengthSnaps() {
        let animator = TypewriterAnimator()

        animator.update(fullText: "hello world")
        animator.commitCurrentAnimation()

        animator.update(fullText: "Hello World")
        #expect(animator.displayText == "Hello World")
    }

    // MARK: - Period Merge

    @Test func periodRemovalPlusAppendIsNotCorrection() {
        let animator = TypewriterAnimator()

        animator.update(fullText: "Hello.")
        animator.commitCurrentAnimation()
        #expect(animator.displayText == "Hello.")

        // Period removed, new text appended — should be treated as append,
        // but small deltas can still snap immediately.
        animator.update(fullText: "Hello world.")
        #expect(!animator.isAnimating, "Short period-merge deltas should snap")
        #expect(animator.displayText == "Hello world.")
    }

    @Test func chinesePeriodMerge() {
        let animator = TypewriterAnimator()

        animator.update(fullText: "\u{8BED}\u{97F3}\u{3002}")
        animator.commitCurrentAnimation()

        animator.update(fullText: "\u{8BED}\u{97F3}\u{662F}\u{53EF}\u{4EE5}\u{3002}")
        #expect(!animator.isAnimating, "Short Chinese period-merge deltas should snap")
        #expect(animator.displayText == "\u{8BED}\u{97F3}\u{662F}\u{53EF}\u{4EE5}\u{3002}")
    }

    @Test func periodOnlyRemovalWithShorterTextIsCorrection() {
        let animator = TypewriterAnimator()

        animator.update(fullText: "Hello world.")
        animator.commitCurrentAnimation()

        // Just removing the period with no new text — this IS a correction
        animator.update(fullText: "Hello world")
        #expect(animator.displayText == "Hello world", "Shorter text should snap")
        #expect(!animator.isAnimating)
    }

    @Test func identicalTextIsNoOp() {
        let animator = TypewriterAnimator()

        animator.update(fullText: "Hello")
        animator.commitCurrentAnimation()

        animator.update(fullText: "Hello")
        #expect(!animator.isAnimating)
        #expect(animator.displayText == "Hello")
    }

    @Test func newUpdateSnapsCurrentAnimation() {
        let animator = TypewriterAnimator()

        let first = "Hello beautiful"
        let second = "Hello beautiful world again"

        // Start first animation
        animator.update(fullText: first)
        #expect(animator.isAnimating)

        // Second update arrives mid-animation — should snap first, start new.
        animator.update(fullText: second)
        #expect(animator.displayText == first)
        #expect(animator.isAnimating)

        animator.commitCurrentAnimation()
        #expect(animator.displayText == second)
    }

    // MARK: - Common Prefix

    // MARK: - Common Prefix

    @Test func commonPrefixCountEmptyStrings() {
        #expect(TypewriterAnimator.commonPrefixCount("", "") == 0)
        #expect(TypewriterAnimator.commonPrefixCount("abc", "") == 0)
        #expect(TypewriterAnimator.commonPrefixCount("", "abc") == 0)
    }

    @Test func commonPrefixCountPartialMatch() {
        #expect(TypewriterAnimator.commonPrefixCount("Hello", "Hello world") == 5)
        #expect(TypewriterAnimator.commonPrefixCount("Hello world", "Hello") == 5)
    }

    @Test func commonPrefixCountFullMatch() {
        #expect(TypewriterAnimator.commonPrefixCount("abc", "abc") == 3)
    }

    @Test func commonPrefixCountNoMatch() {
        #expect(TypewriterAnimator.commonPrefixCount("abc", "xyz") == 0)
    }

    @Test func commonPrefixCountUnicode() {
        // CJK characters
        #expect(TypewriterAnimator.commonPrefixCount("你好世界", "你好朋友") == 2)
        // Emoji
        #expect(TypewriterAnimator.commonPrefixCount("👋🌍", "👋🌎") == 1)
    }

    // MARK: - Animation Completion

    @Test func smallDeltaSnapsImmediately() {
        let animator = TypewriterAnimator()

        animator.update(fullText: "Hi")

        #expect(!animator.isAnimating)
        #expect(animator.displayText == "Hi")
    }

    @Test func animationCompletesNaturally() async throws {
        let animator = TypewriterAnimator()

        let longText = "Hello world"
        animator.update(fullText: longText)
        #expect(animator.isAnimating)

        // Bounded animation should complete well under half a second.
        try await Task.sleep(for: .milliseconds(400))

        #expect(!animator.isAnimating)
        #expect(animator.displayText == longText)
    }

    @Test func animationRevealsCharactersProgressively() async throws {
        let animator = TypewriterAnimator()
        let longText = "ABCDEFGHIJKL"

        animator.update(fullText: longText)

        // Wait a short time — should have revealed some but not all.
        try await Task.sleep(for: .milliseconds(80))

        let partialLength = animator.displayText.count
        #expect(partialLength > 0, "Should have revealed at least one character")
        #expect(partialLength < longText.count, "Should not have revealed all characters yet")
        #expect(animator.isAnimating)
        #expect(animator.visibleAnimatedSuffixLength == partialLength)

        // Wait for completion.
        try await Task.sleep(for: .milliseconds(300))
        #expect(animator.displayText == longText)
        #expect(animator.visibleAnimatedSuffixLength == 0)
    }

    @Test func rapidUpdatesConverge() async throws {
        let animator = TypewriterAnimator()

        // Simulate server updates arriving every 200ms
        animator.update(fullText: "The")
        try await Task.sleep(for: .milliseconds(200))
        animator.update(fullText: "The quick")
        try await Task.sleep(for: .milliseconds(200))
        animator.update(fullText: "The quick brown fox")

        // Commit — should have the latest
        animator.commitCurrentAnimation()
        #expect(animator.displayText == "The quick brown fox")
    }
}
