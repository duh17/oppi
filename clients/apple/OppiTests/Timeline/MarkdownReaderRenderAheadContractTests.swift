import Foundation
import Testing
import UIKit
@testable import Oppi

@Suite("Markdown reader render-ahead contract", .serialized)
struct MarkdownReaderRenderAheadContractTests {
    @Test("same-kind segments from one top-level block receive unique stable IDs")
    func sameKindOccurrenceOrdinalsAreUniqueAndAppendStable() throws {
        let baseURL = try #require(URL(string: "https://server.example.com"))
        let initial = """
        ![first](images/first.png) ![second](images/second.png)

        - nested blocks

          ```swift
          let first = 1
          ```

          ```swift
          let second = 2
          ```
        """
        let appended = initial + "\n\nA trailing paragraph grows."

        let first = build(initial, baseURL: baseURL)
        let second = build(appended, baseURL: baseURL)

        let imageIDs = zip(first.segments, first.identities).compactMap { segment, id in
            if case .image = segment { return id }
            return nil
        }
        #expect(imageIDs.count == 2)
        #expect(Set(imageIDs).count == 2)
        #expect(imageIDs.map(\.occurrenceOrdinal) == [0, 1])
        #expect(imageIDs.map(\.sourceStartLine) == [1, 1])

        let nestedCodeIDs = zip(first.segments, first.identities).compactMap { segment, id in
            if case .codeBlock = segment { return id }
            return nil
        }
        #expect(nestedCodeIDs.count == 2)
        #expect(Set(nestedCodeIDs).count == 2)
        #expect(nestedCodeIDs.map(\.occurrenceOrdinal) == [0, 1])
        #expect(Set(nestedCodeIDs.map(\.sourceStartLine)).count == 1)

        #expect(Array(second.identities.prefix(first.identities.count)) == first.identities)
    }

    @MainActor
    @Test("nested lists keep chat text and export standalone blocks")
    func nestedListChatAndExportRegression() {
        let content = """
        1. Parent service
           - Child A
           - Child B

           ```swift
           let first = 1
           ```

           ```swift
           let second = 2
           ```
        """
        let segments = FlatSegment.build(
            from: parseCommonMark(content),
            themeID: .dark
        )
        let renderedText = segments.compactMap { segment -> String? in
            guard case .text(let attributed) = segment else { return nil }
            return String(attributed.characters)
        }.joined(separator: "\n")
        let codeCount = segments.reduce(into: 0) { count, segment in
            if case .codeBlock = segment { count += 1 }
        }
        #expect(renderedText.contains("1. Parent service"))
        #expect(renderedText.contains("• Child A"))
        #expect(renderedText.contains("• Child B"))
        #expect(codeCount == 2)

        let delegate = ReaderContractTextViewDelegate()
        let stack = UIStackView()
        let applier = AssistantMarkdownSegmentApplier(
            stackView: stack,
            textViewDelegate: delegate
        )
        applier.apply(
            segments: segments,
            config: .make(
                content: content,
                isStreaming: false,
                themeID: .dark,
                renderingMode: .export
            )
        )
        #expect(timelineAllTextRenderViews(in: stack).map(timelineRenderedText).joined().contains("Child B"))
        #expect(timelineAllViews(in: stack).compactMap { $0 as? NativeCodeBlockView }.count == 2)
    }

    @Test("height ledger retains append prefix and rejects stale or wrong-width results")
    func heightLedgerTransitionsAndInvalidation() throws {
        let first = MarkdownReaderSegmentID(kind: .text, sourceStartLine: 1, occurrenceOrdinal: 0)
        let second = MarkdownReaderSegmentID(kind: .image, sourceStartLine: 3, occurrenceOrdinal: 0)
        let third = MarkdownReaderSegmentID(kind: .text, sourceStartLine: 5, occurrenceOrdinal: 0)
        var ledger = MarkdownReaderHeightLedger()

        ledger.applyDocument(
            ids: [first, second],
            estimates: [40, 180],
            canonicalWidth: 351,
            appendOnly: false,
            contentRevisions: [1, 1]
        )
        let generation = ledger.generation
        let firstToken = try #require(ledger.workToken(for: first, canonicalWidth: 351))
        #expect(ledger.commitFinal(
            token: firstToken,
            height: 61,
            anchorID: second
        ) == .init(accepted: true, deltaBeforeAnchor: 21))
        #expect(ledger.finalHeight(for: first, canonicalWidth: 351) == 61)

        ledger.applyDocument(
            ids: [first, second, third],
            estimates: [45, 180, 50],
            canonicalWidth: 351,
            appendOnly: true,
            contentRevisions: [1, 2, 1]
        )
        #expect(ledger.generation == generation)
        #expect(ledger.finalHeight(for: first, canonicalWidth: 351) == 61)

        ledger.invalidateWidth(369)
        #expect(ledger.generation != generation)
        #expect(ledger.finalHeight(for: first, canonicalWidth: 369) == nil)
        #expect(!ledger.commitFinal(
            token: .init(
                id: second,
                contentRevision: 1,
                canonicalWidth: 351,
                generation: generation
            ),
            height: 200,
            anchorID: third
        ).accepted)
    }

    @Test("viewport policy gives interaction priority over tail and focus")
    func viewportPolicyDecisions() {
        var policy = MarkdownReaderViewportPolicy(followsTail: true)
        #expect(policy.handle(.requestFollowTail) == .followTail)
        #expect(policy.handle(.requestPreserveAnchor) == .preserveAnchor)

        #expect(policy.handle(.interactionBegan) == .none)
        #expect(policy.handle(.requestFollowTail) == .none)
        #expect(policy.handle(.requestExplicitFocus) == .none)
        #expect(policy.handle(.requestPreserveAnchor) == .none)

        #expect(policy.handle(.interactionEnded(isNearBottom: true, isStreaming: true)) == .followTail)
        #expect(policy.handle(.streamCompleted) == .none)
        #expect(policy.handle(.requestFollowTail) == .none)
        #expect(policy.handle(.requestExplicitFocus) == .explicitFocus)
    }

    @MainActor
    @Test("touch-down cancels queued follow and focus before the main queue drains")
    func touchDownOwnsViewportBeforeDrag() async throws {
        let content = (0..<70).map {
            "Streaming paragraph \($0) with enough prose to keep the reader scrollable."
        }.joined(separator: "\n\n")
        let stream = ThinkingTraceStream(text: content, isDone: false)
        let body = NativeFullScreenMarkdownBody(
            content: content,
            stream: stream,
            palette: ThemeID.dark.palette,
            reviewCommentSelectionRouter: nil,
            reviewCommentSourceContext: nil
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 844))
        window.addSubview(body)
        body.frame = window.bounds
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        body.layoutIfNeeded()
        let collection = try #require(timelineFirstView(ofType: UICollectionView.self, in: body))
        collection.layoutIfNeeded()
        collection.contentOffset.y = min(240, max(0, collection.contentSize.height - collection.bounds.height))
        let ownedOffset = collection.contentOffset.y
        body.debugResetOffsetWriteReasonsForTesting()

        body.debugQueueAutomaticViewportWritesForTesting(focusY: 0)
        body.debugHandleTouchDownForTesting()
        await drainMainQueue()
        await drainMainQueue()

        #expect(abs(collection.contentOffset.y - ownedOffset) < 1)
        #expect(body.debugOffsetWriteReasonsForTesting.isEmpty)
    }

    @MainActor
    @Test("tail-following append ticks stay pinned and only owner writes follow-tail offsets")
    func tailFollowingAppendStaysPinned() async throws {
        let initial = (0..<55).map {
            "Streaming paragraph \($0) with enough prose to make a tall reader."
        }.joined(separator: "\n\n")
        let stream = ThinkingTraceStream(text: initial, isDone: false)
        let body = NativeFullScreenMarkdownBody(
            content: initial,
            stream: stream,
            palette: ThemeID.dark.palette,
            reviewCommentSelectionRouter: nil,
            reviewCommentSourceContext: nil
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 844))
        window.addSubview(body)
        body.frame = window.bounds
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        body.layoutIfNeeded()
        let collection = try #require(timelineFirstView(ofType: UICollectionView.self, in: body))
        collection.layoutIfNeeded()
        await drainMainQueue()
        body.layoutIfNeeded()
        collection.layoutIfNeeded()

        let oldSize = collection.contentSize.height
        let oldOffset = collection.contentOffset.y
        body.debugResetOffsetWriteReasonsForTesting()
        stream.update(
            text: initial + "\n\nA newly emitted tail paragraph that changes document geometry.",
            isDone: false
        )
        await drainMainQueue()
        body.layoutIfNeeded()
        collection.layoutIfNeeded()
        await drainMainQueue()

        let minimumY = -collection.adjustedContentInset.top
        let bottomY = max(
            minimumY,
            collection.contentSize.height
                - collection.bounds.height
                + collection.adjustedContentInset.bottom
        )
        #expect(abs(collection.contentOffset.y - bottomY) < 1)
        #expect(abs(
            (collection.contentOffset.y - oldOffset)
                - (collection.contentSize.height - oldSize)
        ) < 1)
        #expect(!body.debugOffsetWriteReasonsForTesting.isEmpty)
        #expect(body.debugOffsetWriteReasonsForTesting.allSatisfy { $0 == .followTail })
    }

    @MainActor
    @Test("append ticks retain prefix geometry and a detached reading anchor")
    func appendTicksRetainPrefixAndDetachedAnchor() async throws {
        let initial = (0..<45).map {
            "Stable paragraph \($0) with enough prose to make a tall reader."
        }.joined(separator: "\n\n") + "\n\nMutable tail"
        let stream = ThinkingTraceStream(text: initial, isDone: false)
        let body = NativeFullScreenMarkdownBody(
            content: initial,
            stream: stream,
            palette: ThemeID.dark.palette,
            reviewCommentSelectionRouter: nil,
            reviewCommentSourceContext: nil
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 844))
        window.addSubview(body)
        body.frame = window.bounds
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        body.layoutIfNeeded()
        let collection = try #require(timelineFirstView(ofType: UICollectionView.self, in: body))
        collection.layoutIfNeeded()
        await drainMainQueue()

        body.scrollViewWillBeginDragging(collection)
        collection.contentOffset.y = max(0, collection.contentSize.height / 2)
        body.scrollViewDidEndDragging(collection, willDecelerate: false)
        collection.layoutIfNeeded()
        let anchorBefore = try #require(body.debugVisibleAnchorForTesting())
        let idsBefore = body.debugRenderedSegmentIDsForTesting
        let prefixHeights = idsBefore.dropLast().indices.map {
            body.debugReservedHeightForTesting($0)
        }
        body.debugResetOffsetWriteReasonsForTesting()

        stream.update(text: initial + " grows without moving the reader.", isDone: false)
        await drainMainQueue()
        body.layoutIfNeeded()
        collection.layoutIfNeeded()
        await drainMainQueue()

        let idsAfter = body.debugRenderedSegmentIDsForTesting
        #expect(Array(idsAfter.prefix(idsBefore.count)) == idsBefore)
        for (index, expected) in prefixHeights.enumerated() {
            #expect(body.debugReservedHeightForTesting(index) == expected)
        }
        let anchorAfter = try #require(body.debugVisibleAnchorForTesting())
        #expect(anchorAfter.item == anchorBefore.item)
        #expect(abs(anchorAfter.screenY - anchorBefore.screenY) < 1)
        #expect(!body.debugOffsetWriteReasonsForTesting.contains(.followTail))
        #expect(!body.debugOffsetWriteReasonsForTesting.contains(.explicitFocus))
    }

    @MainActor
    @Test("canonical width and initial visible geometry are final at first display")
    func initialVisibleGeometryUsesCanonicalWidth() throws {
        let content = (0..<30).map {
            "Paragraph \($0) with inline math $x_\($0)^2$ and enough prose to wrap on a phone."
        }.joined(separator: "\n\n")

        for width: CGFloat in [375, 393, 430] {
            let body = NativeFullScreenMarkdownBody(
                content: content,
                stream: nil,
                palette: ThemeID.dark.palette,
                reviewCommentSelectionRouter: nil,
                reviewCommentSourceContext: nil
            )
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 844))
            window.addSubview(body)
            body.frame = window.bounds
            window.makeKeyAndVisible()
            defer { window.isHidden = true }

            body.layoutIfNeeded()
            let collection = try #require(timelineFirstView(ofType: UICollectionView.self, in: body))
            collection.layoutIfNeeded()

            #expect(abs((body.debugCanonicalContentWidthForTesting ?? 0) - (width - 24)) < 0.5)
            for item in collection.indexPathsForVisibleItems.map(\.item) {
                #expect(body.debugHasFinalGeometryForTesting(item))
                let reserved = try #require(body.debugReservedHeightForTesting(item))
                let fitting = try #require(body.debugFittingHeightForTesting(item))
                #expect(abs(reserved - fitting) < 1)
            }
            #expect(body.debugWillDisplayRenderAheadMissCountForTesting == 0)
        }
    }

    @MainActor
    @Test("tracking and decelerating stream ticks keep the mounted snapshot intact")
    func interactionDefersWholeSnapshotMutation() async throws {
        for decelerating in [false, true] {
            let initial = (0..<50).map { "Stable visible paragraph \($0)." }
                .joined(separator: "\n\n")
            let stream = ThinkingTraceStream(text: initial, isDone: false)
            let body = NativeFullScreenMarkdownBody(
                content: initial,
                stream: stream,
                palette: ThemeID.dark.palette,
                reviewCommentSelectionRouter: nil,
                reviewCommentSourceContext: nil
            )
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 844))
            window.addSubview(body)
            body.frame = window.bounds
            window.makeKeyAndVisible()
            defer {
                body.debugSetCollectionUserInteractingForTesting(nil)
                window.isHidden = true
            }

            body.layoutIfNeeded()
            let collection = try #require(timelineFirstView(ofType: UICollectionView.self, in: body))
            collection.layoutIfNeeded()
            body.scrollViewWillBeginDragging(collection)
            if decelerating {
                body.scrollViewDidEndDragging(collection, willDecelerate: true)
            }
            body.debugSetCollectionUserInteractingForTesting(true)
            let visibleBefore = collection.visibleCells.count
            let renderedBefore = body.debugRenderedSourceTextForTesting

            let updated = initial + "\n\nA deferred streaming tail."
            stream.update(text: updated, isDone: false)
            await drainMainQueue()
            collection.layoutIfNeeded()

            #expect(body.debugHasPendingInteractionSnapshotForTesting)
            #expect(body.debugRenderedSourceTextForTesting == renderedBefore)
            #expect(collection.visibleCells.count == visibleBefore)
            #expect(collection.visibleCells.allSatisfy { !$0.contentView.subviews.isEmpty })

            body.debugSetCollectionUserInteractingForTesting(false)
            if decelerating {
                body.scrollViewDidEndDecelerating(collection)
            } else {
                body.scrollViewDidEndDragging(collection, willDecelerate: false)
            }
            let applied = await waitForTimelineCondition(timeoutMs: 2_000) { @MainActor in
                body.debugRenderedSourceTextForTesting == updated
            }
            #expect(applied)
            #expect(!body.debugHasPendingInteractionSnapshotForTesting)
        }
    }

    @MainActor
    @Test("production update defers interaction and retains append prefix state")
    func productionUpdateDefersAndRetainsPrefixState() async throws {
        let initial = (0..<36).map { index in
            "```text\nstable block \(index) \(String(repeating: "word ", count: 10))\n```"
        }.joined(separator: "\n\n")
        let body = NativeFullScreenMarkdownBody(
            content: initial,
            stream: nil,
            isStreaming: true,
            palette: ThemeID.dark.palette,
            reviewCommentSelectionRouter: nil,
            reviewCommentSourceContext: nil
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 844))
        window.addSubview(body)
        body.frame = window.bounds
        window.makeKeyAndVisible()
        defer {
            body.debugSetCollectionUserInteractingForTesting(nil)
            window.isHidden = true
        }

        body.layoutIfNeeded()
        let collection = try #require(timelineFirstView(ofType: UICollectionView.self, in: body))
        collection.layoutIfNeeded()
        body.debugScrollItemIntoViewForTesting(28)
        body.scrollViewWillBeginDragging(collection)
        body.debugSetCollectionUserInteractingForTesting(true)

        let sourceBefore = try #require(body.debugRenderedSourceTextForTesting)
        let idsBefore = body.debugRenderedSegmentIDsForTesting
        let revisionsBefore = body.debugRenderedSegmentRevisionsForTesting
        let committedHeightsBefore = idsBefore.indices.compactMap { index -> (Int, CGFloat)? in
            guard body.debugHasFinalGeometryForTesting(index),
                  let height = body.debugReservedHeightForTesting(index) else { return nil }
            return (index, height)
        }
        #expect(!committedHeightsBefore.isEmpty)
        let parkedBefore = Dictionary(uniqueKeysWithValues: idsBefore.compactMap { id in
            let count = body.debugParkedViewCountForTesting(id: id)
            return count > 0 ? (id, count) : nil
        })
        #expect(!parkedBefore.isEmpty)
        let anchorBefore = try #require(body.debugVisibleAnchorForTesting())

        let updated = initial + "\n\n```text\nappended production update\n```"
        body.update(content: updated, isStreaming: true)
        await drainMainQueue()
        collection.layoutIfNeeded()

        #expect(body.debugHasPendingInteractionSnapshotForTesting)
        #expect(body.debugRenderedSourceTextForTesting == sourceBefore)
        #expect(body.debugRenderedSegmentIDsForTesting == idsBefore)
        #expect(body.debugRenderedSegmentRevisionsForTesting == revisionsBefore)
        #expect(body.debugVisibleAnchorForTesting()?.item == anchorBefore.item)
        #expect(abs((body.debugVisibleAnchorForTesting()?.screenY ?? 10_000) - anchorBefore.screenY) < 1)

        body.debugSetCollectionUserInteractingForTesting(false)
        body.scrollViewDidEndDragging(collection, willDecelerate: false)
        let applied = await waitForTimelineCondition(timeoutMs: 2_000) { @MainActor in
            body.debugRenderedSourceTextForTesting == updated
        }
        #expect(applied)
        body.layoutIfNeeded()
        collection.layoutIfNeeded()

        #expect(Array(body.debugRenderedSegmentIDsForTesting.prefix(idsBefore.count)) == idsBefore)
        for (index, expectedHeight) in committedHeightsBefore {
            #expect(body.debugReservedHeightForTesting(index) == expectedHeight)
        }
        for (id, count) in parkedBefore {
            #expect(body.debugParkedViewCountForTesting(id: id) == count)
        }
        let anchorAfter = try #require(body.debugVisibleAnchorForTesting())
        #expect(anchorAfter.item == anchorBefore.item)
        #expect(abs(anchorAfter.screenY - anchorBefore.screenY) < 1)
    }

    @MainActor
    @Test("reader preferences defer during interaction and preserve a mid-document anchor")
    func readerPreferencesDeferAndPreserveAnchor() async throws {
        let content = (0..<42).map { index in
            "Paragraph \(index) " + String(repeating: "reader preference text ", count: 9)
                + "\n\n---"
        }.joined(separator: "\n\n")
        let body = NativeFullScreenMarkdownBody(
            content: content,
            stream: nil,
            palette: ThemeID.dark.palette,
            reviewCommentSelectionRouter: nil,
            reviewCommentSourceContext: nil
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 844))
        window.addSubview(body)
        body.frame = window.bounds
        window.makeKeyAndVisible()
        defer {
            body.debugSetCollectionUserInteractingForTesting(nil)
            window.isHidden = true
        }

        body.layoutIfNeeded()
        let collection = try #require(timelineFirstView(ofType: UICollectionView.self, in: body))
        collection.layoutIfNeeded()
        body.debugScrollItemIntoViewForTesting(max(0, body.debugRenderedSegmentCountForTesting / 2))
        body.scrollViewWillBeginDragging(collection)
        body.debugSetCollectionUserInteractingForTesting(true)
        let anchorBefore = try #require(body.debugVisibleAnchorForTesting())
        let revisionsBefore = body.debugRenderedSegmentRevisionsForTesting
        let replacementsBefore = body.debugLayoutReplaceCountForTesting

        body.applyReaderPreferences(.init(textScale: 1.3, spacing: .relaxed))
        await drainMainQueue()
        collection.layoutIfNeeded()

        #expect(body.debugRenderedSegmentRevisionsForTesting == revisionsBefore)
        #expect(body.debugLayoutReplaceCountForTesting == replacementsBefore)
        let anchorDuring = try #require(body.debugVisibleAnchorForTesting())
        #expect(anchorDuring.item == anchorBefore.item)
        #expect(abs(anchorDuring.screenY - anchorBefore.screenY) < 1)

        body.debugSetCollectionUserInteractingForTesting(false)
        body.scrollViewDidEndDragging(collection, willDecelerate: false)
        let applied = await waitForTimelineCondition(timeoutMs: 2_000) { @MainActor in
            body.debugLayoutReplacementReasonsForTesting.contains(.readerPreferences)
        }
        #expect(applied)
        body.layoutIfNeeded()
        collection.layoutIfNeeded()
        let anchorAfter = try #require(body.debugVisibleAnchorForTesting())
        #expect(anchorAfter.item == anchorBefore.item)
        #expect(abs(anchorAfter.screenY - anchorBefore.screenY) < 1)
    }

    @MainActor
    @Test("a will-display miss replaces active layout before presentation")
    func willDisplayMissReplacesActiveLayout() throws {
        let content = (0..<30).map { index in
            "```swift\nlet value\(index) = \"\(String(repeating: "wide ", count: 30))\"\n```"
        }.joined(separator: "\n\n")
        let body = NativeFullScreenMarkdownBody(
            content: content,
            stream: nil,
            palette: ThemeID.dark.palette,
            reviewCommentSelectionRouter: nil,
            reviewCommentSourceContext: nil
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 844))
        window.addSubview(body)
        body.frame = window.bounds
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        body.layoutIfNeeded()
        let collection = try #require(timelineFirstView(ofType: UICollectionView.self, in: body))
        collection.layoutIfNeeded()
        let item = body.debugRenderedSegmentCountForTesting - 3
        body.debugForceRenderAheadMissForTesting(item: item, estimate: 44)
        let replacementsBeforeMiss = body.debugLayoutReplaceCountForTesting

        scrollProduction(body: body, collection: collection, item: item)
        #expect(body.debugHasFinalGeometryForTesting(item))
        // The synchronous layout replacement can recycle the original cell;
        // center the now-final item once more before comparing live fitting.
        body.debugScrollItemIntoViewForTesting(item)
        body.debugScrollItemIntoViewForTesting(item)
        let activeHeight = try #require(collection.collectionViewLayout.layoutAttributesForItem(
            at: IndexPath(item: item, section: 0)
        )?.frame.height)
        let fittingHeight = try #require(body.debugFittingHeightForTesting(item))

        #expect(abs(activeHeight - fittingHeight) < 1)
        #expect(body.debugLayoutReplaceCountForTesting > replacementsBeforeMiss)
        #expect(body.debugLayoutReplacementReasonsForTesting.contains(.willDisplayMiss))
        #expect(body.debugWillDisplayRenderAheadMissCountForTesting > 0)
    }

    @MainActor
    @Test("continuous flick presents viewport cells before lift")
    func continuousFlickPresentsViewportCellsBeforeLift() throws {
        let content = (0..<80).map { index in
            "```text\nrunway block \(index) \(String(repeating: "word ", count: 16))\n```"
        }.joined(separator: "\n\n")
        let body = NativeFullScreenMarkdownBody(
            content: content,
            stream: nil,
            palette: ThemeID.dark.palette,
            reviewCommentSelectionRouter: nil,
            reviewCommentSourceContext: nil
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 844))
        window.addSubview(body)
        body.frame = window.bounds
        window.makeKeyAndVisible()
        defer {
            body.debugSetCollectionUserInteractingForTesting(nil)
            window.isHidden = true
        }

        body.layoutIfNeeded()
        let collection = try #require(timelineFirstView(ofType: UICollectionView.self, in: body))
        collection.layoutIfNeeded()
        #expect(body.debugRenderedSegmentCountForTesting == 80)

        body.scrollViewWillBeginDragging(collection)
        body.debugSetCollectionUserInteractingForTesting(true)
        body.debugResetOffsetWriteReasonsForTesting()
        let replacementsBeforeFlick = body.debugLayoutReplaceCountForTesting
        let deepItem = body.debugRenderedSegmentCountForTesting - 8
        scrollProduction(body: body, collection: collection, item: deepItem)

        let visibleItems = collection.indexPathsForVisibleItems.map(\.item).sorted()
        #expect(!visibleItems.isEmpty)
        #expect(visibleItems.contains(where: { $0 >= deepItem - 2 }))
        for item in visibleItems {
            if case .image = body.debugRenderedSegmentsForTesting[item] {
                continue
            }
            #expect(
                body.debugIsItemPresentedForTesting(item),
                "item \(item) stayed blank during the in-progress flick"
            )
        }
        #expect(body.debugOffsetWriteReasonsForTesting.isEmpty)
        #expect(body.debugVisibleHeightCorrectionDuringInteractionCountForTesting == 0)
        #expect(body.debugLayoutReplaceCountForTesting == replacementsBeforeFlick)
        #expect(body.debugNeedsLayoutReplaceAfterInteractionForTesting)
    }

    @MainActor
    @Test("multi-stop ride presents every viewport before lift")
    func multiStopRidePresentsEveryViewportBeforeLift() throws {
        let content = (0..<80).map { index in
            "```text\nride block \(index) \(String(repeating: "word ", count: 16))\n```"
        }.joined(separator: "\n\n")
        let body = NativeFullScreenMarkdownBody(
            content: content,
            stream: nil,
            palette: ThemeID.dark.palette,
            reviewCommentSelectionRouter: nil,
            reviewCommentSourceContext: nil
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 844))
        window.addSubview(body)
        body.frame = window.bounds
        window.makeKeyAndVisible()
        defer {
            body.debugSetCollectionUserInteractingForTesting(nil)
            window.isHidden = true
        }

        body.layoutIfNeeded()
        let collection = try #require(timelineFirstView(ofType: UICollectionView.self, in: body))
        collection.layoutIfNeeded()

        body.scrollViewWillBeginDragging(collection)
        body.debugSetCollectionUserInteractingForTesting(true)
        body.debugResetOffsetWriteReasonsForTesting()
        let replacementsBeforeRide = body.debugLayoutReplaceCountForTesting
        let stops = [0, 20, 40, 60, 72]

        for stop in stops {
            scrollProduction(body: body, collection: collection, item: stop)
            let visibleItems = collection.indexPathsForVisibleItems.map(\.item).sorted()
            #expect(!visibleItems.isEmpty, "stop \(stop) had no visible cells")
            #expect(visibleItems.contains(where: { abs($0 - stop) <= 3 }), "stop \(stop) did not land near the target")
            for item in visibleItems {
                #expect(
                    body.debugIsItemPresentedForTesting(item),
                    "item \(item) stayed blank at ride stop \(stop)"
                )
            }
        }

        #expect(body.debugOffsetWriteReasonsForTesting.isEmpty)
        #expect(body.debugVisibleHeightCorrectionDuringInteractionCountForTesting == 0)
        #expect(body.debugLayoutReplaceCountForTesting == replacementsBeforeRide)

        let anchorBeforeLift = try #require(body.debugVisibleAnchorForTesting())
        body.debugSetCollectionUserInteractingForTesting(false)
        body.scrollViewDidEndDragging(collection, willDecelerate: false)
        collection.layoutIfNeeded()

        let visibleAfterLift = collection.indexPathsForVisibleItems.map(\.item).sorted()
        #expect(!visibleAfterLift.isEmpty)
        for item in visibleAfterLift {
            #expect(body.debugIsItemPresentedForTesting(item))
        }
        let anchorAfterLift = try #require(body.debugVisibleAnchorForTesting())
        #expect(anchorAfterLift.item == anchorBeforeLift.item)
        #expect(abs(anchorAfterLift.screenY - anchorBeforeLift.screenY) < 1)
    }

    @MainActor
    @Test("cold raster and SVG misses stay hidden until prepared geometry is active")
    func coldInternalImageMissesWaitForPreparedGeometry() async throws {
        let raster = try #require(Self.pngData(size: CGSize(width: 80, height: 240)))
        let fixtures: [(name: String, data: Data)] = [
            ("cold.png", raster),
            ("cold.svg", Self.svgData),
        ]

        for fixture in fixtures {
            NativeMarkdownImageView.debugResetPreparedArtifactsForTesting()
            let gate = ReaderImageGate(dataBySuffix: [fixture.name: fixture.data])
            let prefix = (0..<30).map { index in
                "```text\nrunway block \(index) \(String(repeating: "word ", count: 12))\n```"
            }.joined(separator: "\n\n")
            let content = prefix + "\n\n![cold](\(fixture.name))\n\n```text\nanchor after image\n```"
            let body = NativeFullScreenMarkdownBody(
                content: content,
                stream: nil,
                palette: ThemeID.dark.palette,
                reviewCommentSelectionRouter: nil,
                reviewCommentSourceContext: nil,
                workspaceID: "cold-\(fixture.name)",
                serverBaseURL: try #require(URL(string: "https://server.example.com")),
                sourceFilePath: "docs/cold.md",
                fetchWorkspaceFile: { _, path in try await gate.fetch(path: path) }
            )
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 844))
            window.addSubview(body)
            body.frame = window.bounds
            window.makeKeyAndVisible()
            defer { window.isHidden = true }

            body.layoutIfNeeded()
            let collection = try #require(timelineFirstView(ofType: UICollectionView.self, in: body))
            collection.layoutIfNeeded()
            let imageItem = try #require(body.debugRenderedSegmentsForTesting.firstIndex {
                if case .image(_, let url) = $0 { return url.path.hasSuffix(fixture.name) }
                return false
            })

            scrollProduction(body: body, collection: collection, item: imageItem)
            collection.layoutIfNeeded()
            #expect(!body.debugHasFinalGeometryForTesting(imageItem))
            #expect(!body.debugIsItemPresentedForTesting(imageItem))
            #expect(body.debugWillDisplayRenderAheadMissCountForTesting > 0)

            let imageFrame = try #require(collection.collectionViewLayout.layoutAttributesForItem(
                at: IndexPath(item: imageItem, section: 0)
            )?.frame)
            let maximumY = max(
                -collection.adjustedContentInset.top,
                collection.contentSize.height - collection.bounds.height
                    + collection.adjustedContentInset.bottom
            )
            collection.contentOffset.y = min(imageFrame.maxY + 8, maximumY)
            collection.layoutIfNeeded()
            let anchorBefore = try #require(body.debugVisibleAnchorForTesting())
            let commitsBefore = body.debugGeometryCommitCountForTesting
            let replacementsBefore = body.debugLayoutReplaceCountForTesting

            await gate.release()
            let committed = await waitForTimelineCondition(timeoutMs: 3_000) { @MainActor in
                body.debugHasFinalGeometryForTesting(imageItem)
            }
            #expect(committed)
            collection.layoutIfNeeded()
            let anchorAfter = try #require(body.debugVisibleAnchorForTesting())
            #expect(anchorAfter.item == anchorBefore.item)
            #expect(abs(anchorAfter.screenY - anchorBefore.screenY) < 1)
            #expect(body.debugGeometryCommitCountForTesting > commitsBefore)
            #expect(body.debugLayoutReplaceCountForTesting > replacementsBefore)
            #expect(body.debugVisibleHeightCorrectionDuringInteractionCountForTesting == 0)
            #expect(NativeMarkdownImageView.debugPreparedOperationCountForTesting == 1)

            scrollProduction(body: body, collection: collection, item: imageItem)
            let presented = await waitForTimelineCondition(timeoutMs: 3_000) { @MainActor in
                body.debugIsItemPresentedForTesting(imageItem)
            }
            #expect(presented)
            let activeHeight = try #require(collection.collectionViewLayout.layoutAttributesForItem(
                at: IndexPath(item: imageItem, section: 0)
            )?.frame.height)
            let fittingHeight = try #require(body.debugFittingHeightForTesting(imageItem))
            #expect(abs(activeHeight - fittingHeight) < 1)
            #expect(abs((body.debugReservedHeightForTesting(imageItem) ?? 0) - fittingHeight) < 1)
        }
    }

    @MainActor
    @Test("synchronous opening runway has an item budget")
    func initialRunwayIsBounded() throws {
        let content = (0..<80).map { index in
            "```text\nsmall block \(index)\n```"
        }.joined(separator: "\n\n")
        let body = NativeFullScreenMarkdownBody(
            content: content,
            stream: nil,
            palette: ThemeID.dark.palette,
            reviewCommentSelectionRouter: nil,
            reviewCommentSourceContext: nil
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 844))
        window.addSubview(body)
        body.frame = window.bounds
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        body.layoutIfNeeded()

        #expect(body.debugInitialSynchronousPreparationItemCountForTesting <= 8)
        #expect(body.debugRenderedSegmentCountForTesting == 80)
    }

    @MainActor
    @Test("production runway prepares every kind at canonical widths in both scroll directions")
    func productionPathAllKindsWidthMatrix() async throws {
        NativeMarkdownImageView.debugResetPreparedArtifactsForTesting()
        let raster = try #require(Self.pngData(size: CGSize(width: 80, height: 160)))
        let svg = Self.svgData
        let content = Self.allKindsDocument
        let baseURL = try #require(URL(string: "https://server.example.com"))

        for width: CGFloat in [375, 393, 430] {
            let body = NativeFullScreenMarkdownBody(
                content: content,
                stream: nil,
                palette: ThemeID.dark.palette,
                reviewCommentSelectionRouter: nil,
                reviewCommentSourceContext: nil,
                workspaceID: "reader-width-matrix-\(Int(width))",
                serverBaseURL: baseURL,
                sourceFilePath: "docs/matrix.md",
                fetchWorkspaceFile: { _, path in
                    path.hasSuffix("diagram.svg") ? svg : raster
                }
            )
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 844))
            window.addSubview(body)
            body.frame = window.bounds
            window.makeKeyAndVisible()
            defer { window.isHidden = true }

            body.layoutIfNeeded()
            let collection = try #require(timelineFirstView(ofType: UICollectionView.self, in: body))
            collection.layoutIfNeeded()
            let items = Array(body.debugRenderedSegmentsForTesting.indices)
            for item in items + items.reversed() {
                scrollProduction(body: body, collection: collection, item: item)
                let ready = await waitForTimelineCondition(timeoutMs: 3_000) { @MainActor in
                    body.debugHasFinalGeometryForTesting(item)
                }
                #expect(ready, "item \(item) did not become ready at width \(width)")
                if collection.indexPathsForVisibleItems.contains(IndexPath(item: item, section: 0)) {
                    let reserved = try #require(body.debugReservedHeightForTesting(item))
                    let fitting = try #require(body.debugFittingHeightForTesting(item))
                    #expect(abs(reserved - fitting) < 1)
                }
            }

            let canonicalWidth = width - 24
            #expect(abs((body.debugCanonicalContentWidthForTesting ?? 0) - canonicalWidth) < 0.5)
            let allViews = timelineAllViews(in: body)
            let mermaidViews = allViews.compactMap { $0 as? NativeMermaidBlockView }
            let latexViews = allViews.compactMap { $0 as? NativeLatexBlockView }
            let imageViews = allViews.compactMap { $0 as? NativeMarkdownImageView }
            #expect(!mermaidViews.isEmpty)
            #expect(!latexViews.isEmpty)
            #expect(imageViews.count >= 2)
            #expect(mermaidViews.allSatisfy { abs(($0.debugRasterWidthForTesting ?? 0) - canonicalWidth) < 0.5 })
            #expect(latexViews.allSatisfy { abs(($0.debugRenderWidthForTesting ?? 0) - canonicalWidth) < 0.5 })
            #expect(imageViews.allSatisfy { abs(($0.debugPreparedDisplayWidthForTesting ?? 0) - canonicalWidth) < 0.5 })
            #expect(mermaidViews.allSatisfy { $0.debugRenderCountForTesting == 1 })
            #expect(latexViews.allSatisfy { $0.debugRenderCountForTesting == 1 })
            #expect(imageViews.allSatisfy { $0.debugHasPreparedArtifactForTesting })
            #expect(body.debugSynchronousScrollSettlementCountForTesting == 0)
            #expect(body.debugMaxRenderAheadItemsPerSliceForTesting <= 2)
        }
    }

    @MainActor
    @Test("line-anchor gutter overlays canonical graphical content width")
    func lineAnchorUsesCanonicalGraphicalWidthWithoutRerender() async throws {
        NativeMarkdownImageView.debugResetPreparedArtifactsForTesting()
        let raster = try #require(Self.pngData(size: CGSize(width: 80, height: 160)))
        let anchor = try #require(SourceLineAnchor(startLine: 1, endLine: 1))
        let width: CGFloat = 393
        let body = NativeFullScreenMarkdownBody(
            content: Self.allKindsDocument,
            stream: nil,
            palette: ThemeID.dark.palette,
            reviewCommentSelectionRouter: nil,
            reviewCommentSourceContext: nil,
            workspaceID: "line-anchor-width",
            serverBaseURL: try #require(URL(string: "https://server.example.com")),
            sourceFilePath: "docs/anchored.md",
            lineAnchor: anchor,
            focusLineAnchor: false,
            fetchWorkspaceFile: { _, path in
                path.hasSuffix("diagram.svg") ? Self.svgData : raster
            }
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 844))
        window.addSubview(body)
        body.frame = window.bounds
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        body.layoutIfNeeded()
        let collection = try #require(timelineFirstView(ofType: UICollectionView.self, in: body))
        collection.layoutIfNeeded()
        for item in body.debugRenderedSegmentsForTesting.indices {
            scrollProduction(body: body, collection: collection, item: item)
            _ = await waitForTimelineCondition(timeoutMs: 3_000) { @MainActor in
                body.debugHasFinalGeometryForTesting(item)
            }
        }
        await drainMainQueue()
        body.debugLayoutVisibleMarkdownCellsForTesting()

        let canonicalWidth = width - 24
        let allViews = timelineAllViews(in: body)
        let mermaid = allViews.compactMap { $0 as? NativeMermaidBlockView }
        let latex = allViews.compactMap { $0 as? NativeLatexBlockView }
        let images = allViews.compactMap { $0 as? NativeMarkdownImageView }
        #expect(!mermaid.isEmpty)
        #expect(!latex.isEmpty)
        #expect(images.count >= 2)
        let laidOutMermaid = mermaid.filter { $0.bounds.width > 0 }
        let laidOutLatex = latex.filter { $0.bounds.width > 0 }
        let laidOutImages = images.filter { $0.bounds.width > 0 }
        #expect(!laidOutMermaid.isEmpty)
        #expect(!laidOutLatex.isEmpty)
        #expect(laidOutImages.count >= 2)
        #expect(
            laidOutMermaid.allSatisfy { abs($0.bounds.width - canonicalWidth) < 0.5 },
            "mermaid bounds=\(laidOutMermaid.map { $0.bounds.width }) canonical=\(canonicalWidth)"
        )
        #expect(
            laidOutLatex.allSatisfy { abs($0.bounds.width - canonicalWidth) < 0.5 },
            "latex bounds=\(laidOutLatex.map { $0.bounds.width }) canonical=\(canonicalWidth)"
        )
        #expect(
            laidOutImages.allSatisfy { abs($0.bounds.width - canonicalWidth) < 0.5 },
            "image bounds=\(laidOutImages.map { $0.bounds.width }) canonical=\(canonicalWidth)"
        )
        #expect(mermaid.allSatisfy { abs(($0.debugRasterWidthForTesting ?? 0) - canonicalWidth) < 0.5 })
        #expect(latex.allSatisfy { abs(($0.debugRenderWidthForTesting ?? 0) - canonicalWidth) < 0.5 })
        #expect(images.allSatisfy { abs(($0.debugPreparedDisplayWidthForTesting ?? 0) - canonicalWidth) < 0.5 })
        #expect(
            laidOutMermaid.allSatisfy { $0.debugRenderCountForTesting == 1 },
            "mermaid render counts=\(laidOutMermaid.map { $0.debugRenderCountForTesting })"
        )
        #expect(laidOutLatex.allSatisfy { $0.debugRenderCountForTesting == 1 })
    }

    @MainActor
    @Test("chat publishes raster metadata geometry before joined decode completes")
    func chatPublishesRasterMetadataBeforeDecode() async throws {
        NativeMarkdownImageView.debugResetPreparedArtifactsForTesting()
        let decodeGate = ReaderDecodeGate()
        NativeMarkdownImageView.debugRasterDecodeGateForTesting = {
            await decodeGate.wait()
        }
        defer {
            NativeMarkdownImageView.debugRasterDecodeGateForTesting = nil
        }

        let data = try #require(Self.pngData(size: CGSize(width: 80, height: 240)))
        let markdown = AssistantMarkdownContentView()
        markdown.fetchWorkspaceFile = { _, _ in data }
        markdown.frame = CGRect(x: 0, y: 0, width: 320, height: 500)
        let window = UIWindow(frame: markdown.frame)
        window.addSubview(markdown)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        markdown.apply(configuration: .make(
            content: "![chat raster](chat.png)",
            isStreaming: false,
            themeID: .dark,
            workspaceID: "chat-metadata",
            serverBaseURL: try #require(URL(string: "https://server.example.com")),
            sourceFilePath: "docs/chat.md",
            renderingMode: .live
        ))
        markdown.layoutIfNeeded()

        let metadataPublished = await waitForTimelineCondition(timeoutMs: 2_000) { @MainActor in
            guard let imageView = timelineFirstView(ofType: NativeMarkdownImageView.self, in: markdown) else {
                return false
            }
            return (imageView.debugPixelReservedHeightForTesting ?? 0) > 180
                && !imageView.debugHasPreparedArtifactForTesting
        }
        let imageView = timelineFirstView(ofType: NativeMarkdownImageView.self, in: markdown)
        let decodeIsWaiting = await decodeGate.isWaiting
        #expect(
            metadataPublished,
            "metadata height=\(String(describing: imageView?.debugPixelReservedHeightForTesting)) decodeWaiting=\(decodeIsWaiting) imageView=\(imageView != nil)"
        )

        await decodeGate.release()
        let decoded = await waitForTimelineCondition(timeoutMs: 2_000) { @MainActor in
            guard let imageView = timelineFirstView(ofType: NativeMarkdownImageView.self, in: markdown) else {
                return false
            }
            return timelineAllImageViews(in: imageView).contains { $0.image != nil }
        }
        #expect(decoded)
    }

    @MainActor
    @Test("SVG runway commits metadata without constructing WebKit until display")
    func svgRunwayUsesMetadataOnlyUntilDisplay() async throws {
        NativeMarkdownImageView.debugResetPreparedArtifactsForTesting()
        let gate = ReaderImageGate(dataBySuffix: ["diagram.svg": Self.svgData])
        let prefix = (0..<35).map { "Tall prefix paragraph \($0) " + String(repeating: "word ", count: 18) }
            .joined(separator: "\n\n")
        let content = prefix + "\n\n![vector](diagram.svg)\n\nTrailing text."
        let body = NativeFullScreenMarkdownBody(
            content: content,
            stream: nil,
            palette: ThemeID.dark.palette,
            reviewCommentSelectionRouter: nil,
            reviewCommentSourceContext: nil,
            workspaceID: "svg-gate",
            serverBaseURL: try #require(URL(string: "https://server.example.com")),
            sourceFilePath: "docs/svg.md",
            fetchWorkspaceFile: { _, path in try await gate.fetch(path: path) }
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 844))
        window.addSubview(body)
        body.frame = window.bounds
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        body.layoutIfNeeded()
        let collection = try #require(timelineFirstView(ofType: UICollectionView.self, in: body))
        collection.layoutIfNeeded()
        let svgItem = try #require(body.debugRenderedSegmentsForTesting.firstIndex {
            if case .image(_, let url) = $0 { return url.path.hasSuffix("diagram.svg") }
            return false
        })

        // Ask the production prefetch callback for the offscreen item, then
        // release metadata while it remains outside the viewport.
        body.collectionView(collection, prefetchItemsAt: [IndexPath(item: svgItem, section: 0)])
        await gate.release()
        let preparedOffscreen = await waitForTimelineCondition(timeoutMs: 3_000) { @MainActor in
            timelineAllViews(in: body)
                .compactMap { $0 as? NativeMarkdownImageView }
                .contains { $0.debugIsSVGArtifactForTesting }
        }
        #expect(preparedOffscreen)
        let offscreenSVGViews = timelineAllViews(in: body)
            .compactMap { $0 as? NativeMarkdownImageView }
            .filter(\.debugIsSVGArtifactForTesting)
        #expect(!offscreenSVGViews.isEmpty)
        #expect(offscreenSVGViews.allSatisfy { !$0.debugHasSVGWebViewForTesting })

        scrollProduction(body: body, collection: collection, item: svgItem)
        let activated = await waitForTimelineCondition(timeoutMs: 3_000) { @MainActor in
            timelineAllViews(in: collection)
                .compactMap { $0 as? NativeMarkdownImageView }
                .contains { $0.debugHasSVGWebViewForTesting }
        }
        #expect(activated)
    }

    @MainActor
    @Test("runway and display waiters join one prepared raster operation")
    func imageWaitersJoinPreparedArtifactWork() async throws {
        NativeMarkdownImageView.debugResetPreparedArtifactsForTesting()
        let data = try #require(Self.pngData(size: CGSize(width: 80, height: 160)))
        let gate = ReaderImageGate(dataBySuffix: ["joined.png": data])
        let url = try #require(URL(string: "https://server.example.com/workspaces/join/raw/joined.png"))
        let runway = NativeMarkdownImageView()
        let display = NativeMarkdownImageView()
        for (view, preparesForDisplay) in [(runway, false), (display, true)] {
            view.apply(
                url: url,
                alt: "joined",
                fetchWorkspaceFile: { _, path in try await gate.fetch(path: path) },
                fetchSessionFile: nil,
                renderingMode: .staticReader,
                preferredDisplayWidth: 369,
                preparesForDisplay: preparesForDisplay
            )
        }

        await gate.release()
        let bothReady = await waitForTimelineCondition(timeoutMs: 3_000) { @MainActor in
            runway.debugHasPreparedArtifactForTesting
                && display.debugHasPreparedArtifactForTesting
        }
        #expect(bothReady)
        let fetchCount = await gate.fetchCount
        #expect(fetchCount == 1)
        #expect(NativeMarkdownImageView.debugPreparedOperationCountForTesting == 1)
    }

    @MainActor
    @Test("stale same-index image completion cannot commit into reparsed content")
    func staleImageResultIsRejectedByImmutableToken() async throws {
        NativeMarkdownImageView.debugResetPreparedArtifactsForTesting()
        let oldGate = ReaderImageGate(dataBySuffix: [
            "old.png": try #require(Self.pngData(size: CGSize(width: 100, height: 100)))
        ])
        let newGate = ReaderImageGate(dataBySuffix: [
            "new.png": try #require(Self.pngData(size: CGSize(width: 60, height: 180)))
        ])
        let baseURL = try #require(URL(string: "https://server.example.com"))
        let initial = "![old](old.png)"
        let body = NativeFullScreenMarkdownBody(
            content: initial,
            stream: nil,
            palette: ThemeID.dark.palette,
            reviewCommentSelectionRouter: nil,
            reviewCommentSourceContext: nil,
            workspaceID: "stale-image",
            serverBaseURL: baseURL,
            sourceFilePath: "docs/race.md",
            fetchWorkspaceFile: { _, path in
                if path.hasSuffix("old.png") { return try await oldGate.fetch(path: path) }
                return try await newGate.fetch(path: path)
            }
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 844))
        window.addSubview(body)
        body.frame = window.bounds
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        body.layoutIfNeeded()
        let collection = try #require(timelineFirstView(ofType: UICollectionView.self, in: body))
        collection.layoutIfNeeded()
        let oldRevision = try #require(body.debugRenderedSegmentRevisionsForTesting.first)

        body.update(content: "![new](new.png)", isStreaming: false)
        body.layoutIfNeeded()
        collection.layoutIfNeeded()
        let newRevision = try #require(body.debugRenderedSegmentRevisionsForTesting.first)
        #expect(newRevision != oldRevision)
        let heightBeforeOldCompletion = try #require(body.debugReservedHeightForTesting(0))

        await oldGate.release()
        await drainMainQueue()
        await drainMainQueue()
        #expect(body.debugReservedHeightForTesting(0) == heightBeforeOldCompletion)

        await newGate.release()
        let newCommitted = await waitForTimelineCondition(timeoutMs: 3_000) { @MainActor in
            (body.debugReservedHeightForTesting(0) ?? 0) > heightBeforeOldCompletion + 100
        }
        #expect(newCommitted)
        #expect(body.debugHasFinalGeometryForTesting(0))
    }

    @MainActor
    @Test("graphical eviction keeps committed geometry and anchor on production redisplay")
    func graphicalEvictionRetainsGeometry() async throws {
        let body = NativeFullScreenMarkdownBody(
            content: Self.allKindsDocument,
            stream: nil,
            palette: ThemeID.dark.palette,
            reviewCommentSelectionRouter: nil,
            reviewCommentSourceContext: nil
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 844))
        window.addSubview(body)
        body.frame = window.bounds
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        body.layoutIfNeeded()
        let collection = try #require(timelineFirstView(ofType: UICollectionView.self, in: body))
        collection.layoutIfNeeded()
        let item = try #require(body.debugRenderedSegmentsForTesting.firstIndex {
            if case .mermaidDiagram = $0 { return true }
            return false
        })
        scrollProduction(body: body, collection: collection, item: item)
        let height = try #require(body.debugReservedHeightForTesting(item))
        let replacementsBeforeEviction = body.debugLayoutReplaceCountForTesting
        let commitsBeforeEviction = body.debugGeometryCommitCountForTesting
        let anchorBeforeEviction = try #require(body.debugVisibleAnchorForTesting())
        scrollProduction(body: body, collection: collection, item: body.debugRenderedSegmentCountForTesting - 1)
        body.debugEvictGraphicalArtifactForTesting(item)
        scrollProduction(body: body, collection: collection, item: item)
        let anchorAfterRedisplay = try #require(body.debugVisibleAnchorForTesting())
        await drainMainQueue()
        let afterDrain = try #require(body.debugVisibleAnchorForTesting())
        #expect(body.debugReservedHeightForTesting(item) == height)
        #expect(anchorAfterRedisplay.item == anchorBeforeEviction.item)
        #expect(abs(anchorAfterRedisplay.screenY - anchorBeforeEviction.screenY) < 1)
        #expect(afterDrain.item == anchorAfterRedisplay.item)
        #expect(abs(afterDrain.screenY - anchorAfterRedisplay.screenY) < 1)
        #expect(body.debugLayoutReplaceCountForTesting == replacementsBeforeEviction)
        #expect(body.debugGeometryCommitCountForTesting == commitsBeforeEviction)
    }

    @MainActor
    private func scrollProduction(
        body: NativeFullScreenMarkdownBody,
        collection: UICollectionView,
        item: Int
    ) {
        guard let frame = collection.collectionViewLayout.layoutAttributesForItem(
            at: IndexPath(item: item, section: 0)
        )?.frame else { return }
        let minimumY = -collection.adjustedContentInset.top
        let maximumY = max(
            minimumY,
            collection.contentSize.height - collection.bounds.height
                + collection.adjustedContentInset.bottom
        )
        collection.setContentOffset(
            CGPoint(x: collection.contentOffset.x, y: min(max(frame.midY - collection.bounds.height / 2, minimumY), maximumY)),
            animated: false
        )
        body.scrollViewDidScroll(collection)
        collection.layoutIfNeeded()
    }

    private static let allKindsDocument = """
    # Reader matrix

    Introductory text with inline math $x^2 + y^2$.

    ```swift
    let value = 42
    ```

    | Kind | Ready |
    | --- | --- |
    | table | yes |

    ---

    ```mermaid
    graph TD
      A[Start] --> B[Ready]
    ```

    ```latex
    \\frac{a + b}{c}
    ```

    ![raster](raster.png)

    ![vector](diagram.svg)

    """ + (0..<30).map { "Trailing paragraph \($0) " + String(repeating: "word ", count: 16) }
        .joined(separator: "\n\n")

    private static let svgData = Data("""
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 100">
      <rect width="200" height="100" fill="#4a90e2"/>
    </svg>
    """.utf8)

    @MainActor
    private static func pngData(size: CGSize) -> Data? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }.pngData()
    }

    @MainActor
    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func build(_ source: String, baseURL: URL) -> FlatSegment.BuildResult {
        FlatSegment.buildWithSourceLineRanges(
            from: parseCommonMarkLocated(source),
            themeID: .dark,
            workspaceID: "workspace",
            serverBaseURL: baseURL,
            sourceDirectory: "docs",
            mergeAdjacentTextSegments: false
        )
    }
}

@MainActor
private final class ReaderContractTextViewDelegate: NSObject, UITextViewDelegate {}

private actor ReaderDecodeGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var isWaiting: Bool { !waiters.isEmpty }

    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        released = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private actor ReaderImageGate {
    enum Error: Swift.Error { case missingFixture(String) }

    private let dataBySuffix: [String: Data]
    private var released = false
    private(set) var fetchCount = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(dataBySuffix: [String: Data]) {
        self.dataBySuffix = dataBySuffix
    }

    func fetch(path: String) async throws -> Data {
        fetchCount += 1
        if !released {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
        guard let pair = dataBySuffix.first(where: { path.hasSuffix($0.key) }) else {
            throw Error.missingFixture(path)
        }
        return pair.value
    }

    func release() {
        released = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}
