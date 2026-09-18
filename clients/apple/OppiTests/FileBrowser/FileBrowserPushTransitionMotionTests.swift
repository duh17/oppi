import Testing
@testable import Oppi

@Suite("File push transition Reduce Motion")
struct FileBrowserPushTransitionMotionTests {
    @Test func reduceMotionDropsDirectionalTravelAndAnimation() {
        #expect(FileBrowserPushTransitionPolicy.directionalSpec(for: .next, reduceMotion: true) == nil)
        #expect(FileBrowserPushTransitionPolicy.directionalSpec(for: .previous, reduceMotion: true) == nil)
        #expect(
            FileBrowserPushTransitionPolicy.animation(reduceMotion: true)
                == ThemeMotion.easeInOut(duration: FileBrowserPushTransitionPolicy.duration, reduceMotion: true)
        )
        #expect(FileBrowserPushTransitionPolicy.animation(reduceMotion: true) == nil)
    }

    @Test func originalDirectionAndTimingRemainWhenReduceMotionIsOff() {
        #expect(
            FileBrowserPushTransitionPolicy.directionalSpec(for: .next, reduceMotion: false)
                == FileBrowserPushTransitionSpec.spec(for: .next)
        )
        #expect(
            FileBrowserPushTransitionPolicy.directionalSpec(for: .previous, reduceMotion: false)
                == FileBrowserPushTransitionSpec.spec(for: .previous)
        )
        #expect(FileBrowserPushTransitionSpec.spec(for: .next) == .init(insertion: .trailing, removal: .leading))
        #expect(FileBrowserPushTransitionSpec.spec(for: .previous) == .init(insertion: .leading, removal: .trailing))
        #expect(
            FileBrowserPushTransitionPolicy.animation(reduceMotion: false)
                == ThemeMotion.easeInOut(duration: FileBrowserPushTransitionPolicy.duration, reduceMotion: false)
        )
        #expect(FileBrowserPushTransitionPolicy.animation(reduceMotion: false) != nil)
    }

    @Test func ordinaryPreviousAndNextDoNotWrapAtBoundaries() {
        let context = FileBrowserNavigationContext(files: [
            FileBrowserSelection(path: "a.swift", name: "a.swift", size: 1),
            FileBrowserSelection(path: "b.swift", name: "b.swift", size: 1),
            FileBrowserSelection(path: "c.swift", name: "c.swift", size: 1),
        ])

        #expect(context.selection(adjacentTo: "b.swift", direction: .previous)?.path == "a.swift")
        #expect(context.selection(adjacentTo: "b.swift", direction: .next)?.path == "c.swift")
        #expect(context.selection(adjacentTo: "a.swift", direction: .previous) == nil)
        #expect(context.selection(adjacentTo: "c.swift", direction: .next) == nil)
        #expect(
            AdjacentFileNavigatorLayout.slots(
                canGoPrevious: false,
                canGoNext: true,
                placement: .leadingPill
            )
                .map(\.accessibilityLabel) == ["Next file"]
        )
        #expect(
            AdjacentFileNavigatorLayout.slots(
                canGoPrevious: true,
                canGoNext: false,
                placement: .leadingPill
            )
                .map(\.accessibilityLabel) == ["Previous file"]
        )
    }

    @Test func reviewPreviousAndNextDoNotWrapAndKeepLoadingReplacement() {
        let files = [
            makeReviewFile(path: "one.swift"),
            makeReviewFile(path: "two.swift"),
            makeReviewFile(path: "two.swift"),
            makeReviewFile(path: "three.swift"),
        ]

        #expect(
            WorkspaceReviewFileNavigationPolicy.adjacentFile(
                in: files,
                currentPath: "two.swift",
                direction: .previous
            )?.path == "one.swift"
        )
        #expect(
            WorkspaceReviewFileNavigationPolicy.adjacentFile(
                in: files,
                currentPath: "two.swift",
                direction: .next
            )?.path == "three.swift"
        )
        #expect(
            WorkspaceReviewFileNavigationPolicy.adjacentFile(
                in: files,
                currentPath: "one.swift",
                direction: .previous
            ) == nil
        )
        #expect(
            WorkspaceReviewFileNavigationPolicy.adjacentFile(
                in: files,
                currentPath: "three.swift",
                direction: .next
            ) == nil
        )
        #expect(WorkspaceReviewFileNavigationPolicy.navigationFiles(files).map(\.path) == [
            "one.swift",
            "two.swift",
            "three.swift",
        ])
        #expect(WorkspaceReviewFileDetailPhase.resolve(diff: nil, error: "stale") == .unavailable("stale"))
        #expect(WorkspaceReviewFileDetailPhase.resolve(diff: nil, error: nil) == .loading)
    }
}

private func makeReviewFile(path: String) -> WorkspaceReviewFile {
    WorkspaceReviewFile(
        path: path,
        status: "M",
        addedLines: 1,
        removedLines: 1,
        isStaged: false,
        isUnstaged: true,
        isUntracked: false,
        selectedSessionTouched: true
    )
}
