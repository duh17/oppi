import SwiftUI
import Testing
import UIKit
@testable import Oppi

@MainActor
@Suite("Native full-screen terminal sidecar windows")
struct NativeFullScreenTerminalWindowTests {
    @Test func liveReaderKeepsCallOwnerWhenItsRowStreamIsReused() async throws {
        struct UnexpectedSidecar: Error {}
        let owner = TerminalOutputStream { _ in throw UnexpectedSidecar() }
        let stream = TerminalTraceStream(output: "", command: nil, isDone: false)
        stream.owner = owner
        let body = NativeFullScreenTerminalBody(content: "", command: nil, stream: stream,
            palette: ThemeRuntimeState.currentThemeID().palette,
            reviewCommentSelectionRouter: nil, reviewCommentSourceContext: nil)
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        body.frame = host.bounds
        host.addSubview(body)
        owner.receive(.init(epoch: 1, offset: 0, bytes: 4), output: "old\r")
        owner.receive(.init(epoch: 1, offset: 4, bytes: 4), output: "new\n")
        let painted = await waitForMainActorCondition(timeout: .seconds(3)) {
            host.layoutIfNeeded()
            return Self.textViews(in: body).contains { $0.textStorage.string == "new\n" }
        }
        #expect(painted)
        owner.markReconnecting()
        func showsResyncNotice(_ view: UIView) -> Bool {
            if let label = view as? UILabel, !label.isHidden, label.text == "Resyncing terminal output…" { return true }
            return view.subviews.contains { showsResyncNotice($0) }
        }
        #expect(showsResyncNotice(body))
        #expect(await body.resolvedCopyText() == "new\n")
        // Simulate the reusable row being rebound to a different call.
        let other = TerminalOutputStream { _ in throw UnexpectedSidecar() }
        stream.owner = other
        stream.update(output: "wrong call", command: nil, isDone: false)
        owner.receive(.init(epoch: 1, offset: 8, bytes: 5), output: "tail\n")
        owner.finish(.init(epoch: 1, totalBytes: 13))
        #expect(await body.resolvedCopyText() == "new\ntail\n")
        #expect(!Self.textViews(in: body).contains { $0.textStorage.string.contains("wrong call") })
    }

    @Test func openLiveReaderRebindsAfterHistoryReloadWithoutFollowingOtherCalls() async throws {
        let reducer = TimelineReducer()
        let store = reducer.terminalOutputStreams
        let owner = store.ensureOwner(for: "call")
        let stream = TerminalTraceStream(output: "", command: nil, isDone: false)
        stream.owner = owner
        stream.ownerStore = store
        stream.ownerToolCallId = "call"
        let body = NativeFullScreenTerminalBody(content: "", command: nil, stream: stream,
            palette: ThemeRuntimeState.currentThemeID().palette,
            reviewCommentSelectionRouter: nil, reviewCommentSourceContext: nil)
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        body.frame = host.bounds
        host.addSubview(body)
        owner.receive(.init(epoch: 1, offset: 0, bytes: 4), output: "old\n")
        let initialPaint = await waitForMainActorCondition(timeout: .seconds(3)) {
            host.layoutIfNeeded()
            return Self.textViews(in: body).contains { $0.textStorage.string == "old\n" }
        }
        #expect(initialPaint)
        #expect(owner.state == .live)
        #expect(await body.resolvedCopyText() == "old\n")

        // A full trace rebuild discards the owner while the reader stays open.
        reducer.loadSession([])
        #expect(Self.showsReloadNotice(body))
        let other = store.ensureOwner(for: "other")
        other.receive(.init(epoch: 1, offset: 0, bytes: 6), output: "wrong\n")
        other.finish(.init(epoch: 1, totalBytes: 6))
        #expect(Self.showsReloadNotice(body))
        let replacement = store.ensureOwner(for: "call")
        #expect(Self.textViews(in: body).contains { $0.textStorage.string == "old\n" },
            "A replacement owner must not clear the reader before its first paint")
        replacement.receive(.init(epoch: 1, offset: 0, bytes: 4), output: "new\n")
        replacement.finish(.init(epoch: 1, totalBytes: 4))
        let painted = await waitForMainActorCondition(timeout: .seconds(3)) {
            host.layoutIfNeeded()
            return Self.textViews(in: body).contains { $0.textStorage.string == "new\n" }
        }
        #expect(painted)
        #expect(await body.resolvedCopyText() == "new\n")
        #expect(!Self.showsReloadNotice(body))
    }

    private static func showsReloadNotice(_ view: UIView) -> Bool {
        if let label = view as? UILabel, !label.isHidden,
           label.text == "Terminal output reloaded; waiting for live stream…" { return true }
        return view.subviews.contains { showsReloadNotice($0) }
    }

    @Test func completionLoadsFullRawHistoryEvenWhenFormattedRingIsLarger() async throws {
        let raw = "early history\n" + String(repeating: "\u{1B}[32mx\n", count: 2200)
        struct Unavailable: Error {}
        let owner = TerminalOutputStream { _ in throw Unavailable() }
        owner.receive(.init(epoch: 1, offset: 0, bytes: raw.utf8.count), output: raw)
        owner.finish(.init(epoch: 1, totalBytes: raw.utf8.count))
        #expect(owner.formatted.utf8.count >= raw.utf8.count)
        #expect(!owner.formatted.contains("early history"))
        let stream = TerminalTraceStream(output: "", command: nil, isDone: true)
        stream.owner = owner
        stream.completionSidecarSource = .init(
            loadFirst: { .init(text: raw, endByteOffset: raw.utf8.count, totalBytes: raw.utf8.count) },
            loadNext: { _ in nil })
        let body = NativeFullScreenTerminalBody(content: "", command: nil, stream: stream,
            palette: ThemeRuntimeState.currentThemeID().palette,
            reviewCommentSelectionRouter: nil, reviewCommentSourceContext: nil)
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        body.frame = host.bounds
        host.addSubview(body)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            host.layoutIfNeeded()
            return Self.textViews(in: body).contains { $0.textStorage.string.contains("early history") }
        })
    }

    @Test func historyReloadWithoutReplacementLoadsSidecarInsteadOfWaiting() async throws {
        let store = TerminalOutputStreamStore()
        let owner = store.ensureOwner(for: "call")
        let stream = TerminalTraceStream(output: "", command: nil, isDone: false)
        stream.owner = owner
        stream.ownerStore = store
        stream.ownerToolCallId = "call"
        stream.completionSidecarSource = .init(
            loadFirst: { .init(text: "full history\n", endByteOffset: 13, totalBytes: 13) },
            loadNext: { _ in nil })
        let body = NativeFullScreenTerminalBody(content: "", command: nil, stream: stream,
            palette: ThemeRuntimeState.currentThemeID().palette,
            reviewCommentSelectionRouter: nil, reviewCommentSourceContext: nil)
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        body.frame = host.bounds
        host.addSubview(body)
        store.clearAll()
        #expect(await waitForMainActorCondition(timeout: .seconds(3)) {
            host.layoutIfNeeded()
            return Self.textViews(in: body).contains { $0.textStorage.string == "full history\n" }
        })
        #expect(!Self.showsReloadNotice(body))
    }

    @Test func replacementOwnerCancelsReloadSidecarCommit() async throws {
        actor SidecarGate {
            var waiter: CheckedContinuation<Void, Never>?
            var requested = false
            func load() async -> ToolOutputSidecarWindow? {
                await withCheckedContinuation { continuation in
                    requested = true
                    waiter = continuation
                }
                return .init(text: "stale history\n", endByteOffset: 14, totalBytes: 14)
            }
            func release() { waiter?.resume(); waiter = nil }
        }
        let gate = SidecarGate()
        let store = TerminalOutputStreamStore()
        let stream = TerminalTraceStream(output: "", command: nil, isDone: false)
        stream.owner = store.ensureOwner(for: "call")
        stream.ownerStore = store
        stream.ownerToolCallId = "call"
        stream.completionSidecarSource = .init(loadFirst: { await gate.load() }, loadNext: { _ in nil })
        let body = NativeFullScreenTerminalBody(content: "", command: nil, stream: stream,
            palette: ThemeRuntimeState.currentThemeID().palette,
            reviewCommentSelectionRouter: nil, reviewCommentSourceContext: nil)
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        body.frame = host.bounds
        host.addSubview(body)
        store.clearAll()
        #expect(await waitForTimelineCondition(timeoutMs: 1_000) { await gate.requested })
        let replacement = store.ensureOwner(for: "call")
        replacement.receive(.init(epoch: 1, offset: 0, bytes: 5), output: "live\n")
        await gate.release()
        #expect(await waitForMainActorCondition(timeout: .seconds(3)) {
            host.layoutIfNeeded()
            return Self.textViews(in: body).contains { $0.textStorage.string == "live\n" }
        })
        #expect(!Self.textViews(in: body).contains { $0.textStorage.string.contains("stale history") })
        replacement.discard()
    }

    @Test func resyncNoticeIsVisibleAtReaderTail() async throws {
        let store = TerminalOutputStreamStore()
        let owner = store.ensureOwner(for: "call")
        let stream = TerminalTraceStream(output: "", command: nil, isDone: false)
        stream.owner = owner
        let body = NativeFullScreenTerminalBody(content: "", command: nil, stream: stream,
            palette: ThemeRuntimeState.currentThemeID().palette,
            reviewCommentSelectionRouter: nil, reviewCommentSourceContext: nil)
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        body.frame = host.bounds
        host.addSubview(body)
        let raw = String(repeating: "line of output\n", count: 1800)
        owner.receive(.init(epoch: 1, offset: 0, bytes: raw.utf8.count), output: raw)
        #expect(await waitForMainActorCondition(timeout: .seconds(3)) {
            host.layoutIfNeeded()
            return (body.virtualizationDiagnosticsForTesting()?.mountedUTF16Count ?? 0) > 0
        })
        owner.markReconnecting()
        host.layoutIfNeeded()
        let scroll = try #require(body.subviews.compactMap { $0 as? UIScrollView }.first { !$0.isHidden })
        scroll.setContentOffset(CGPoint(x: 0, y: max(0, scroll.contentSize.height - scroll.bounds.height)), animated: false)
        host.layoutIfNeeded()
        let notice = try #require(Self.labels(in: body).first { $0.text == "Resyncing terminal output…" })
        #expect(!notice.isHidden)
        #expect(notice.superview === body.subviews.first { $0 is UIStackView },
            "The status line must be outside both scrolling content surfaces")
        #expect(await waitForMainActorCondition(timeout: .seconds(3)) {
            host.layoutIfNeeded()
            return notice.bounds.width > 0 && notice.bounds.height > 0
                && body.bounds.contains(notice.convert(notice.bounds, to: body))
        })
    }

    private static func labels(in view: UIView) -> [UILabel] {
        (view as? UILabel).map { [$0] } ?? view.subviews.flatMap { labels(in: $0) }
    }

    @Test func terminalBodyPaintsFirstWindowAndLaterCursorRewrite() async throws {
        let previousTheme = ThemeRuntimeState.currentThemeID()
        defer { ThemeRuntimeState.setThemeID(previousTheme) }
        ThemeRuntimeState.setThemeID(.dark)
        let first = "\u{1B}[32m" + String(repeating: "green line\n", count: 20_000)
        let rest = "\u{1B}[1A\r\u{1B}[2Kstill green after cursor rewrite\n"
        let body = NativeFullScreenTerminalBody(content: first, command: "bash", stream: nil,
            palette: ThemeID.dark.palette, reviewCommentSelectionRouter: nil, reviewCommentSourceContext: nil)
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        body.frame = host.bounds
        host.addSubview(body)
        host.layoutIfNeeded()

        let firstPaint = await waitForMainActorCondition(timeout: .seconds(5)) {
            host.layoutIfNeeded()
            guard let diagnostics = body.virtualizationDiagnosticsForTesting() else { return false }
            return diagnostics.retainedSourceUTF8Count == first.utf8.count
                && diagnostics.chunkCount > 1 && diagnostics.mountedUTF16Count > 0
        }
        #expect(firstPaint)
        let before = try #require(body.virtualizationDiagnosticsForTesting())
        #expect(before.retainedSourceUTF8Count < (first + rest).utf8.count)
        #expect(before.mountedUTF16Count < first.utf16.count / 4)

        body.appendOutputWindow(rest)
        let appended = await waitForMainActorCondition(timeout: .seconds(5)) {
            host.layoutIfNeeded()
            guard let diagnostics = body.virtualizationDiagnosticsForTesting() else { return false }
            return diagnostics.retainedSourceUTF8Count == (first + rest).utf8.count
                && diagnostics.chunkCount > 1 && diagnostics.mountedUTF16Count > 0
        }
        #expect(appended)
        let collection = try #require(body.subviews.compactMap { $0 as? UICollectionView }.first)
        collection.setContentOffset(CGPoint(x: 0, y: max(0, collection.contentSize.height - collection.bounds.height)), animated: false)
        let rewritten = await waitForMainActorCondition(timeout: .seconds(5)) {
            host.layoutIfNeeded()
            return Self.visibleTextViews(in: collection).contains { $0.textStorage.string.contains("still green after cursor rewrite") }
        }
        #expect(rewritten)
        let view = try #require(Self.visibleTextViews(in: collection).first { $0.textStorage.string.contains("still green after cursor rewrite") })
        let range = (view.textStorage.string as NSString).range(of: "still green")
        #expect(view.textStorage.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? UIColor
            == UIColor(ThemeID.dark.palette.green))
        #expect(body.virtualizationDiagnosticsForTesting()?.cachedChunkCount ?? 100 <= 14)
    }

    @Test func liveReplayKeepsMountedReaderAndDetachedViewport() async throws {
        let first = (0..<20_000).map { "line \($0)\n" }.joined()
        let stream = TerminalTraceStream(output: first, command: nil, isDone: false)
        let body = NativeFullScreenTerminalBody(content: first, command: nil, stream: stream,
            palette: ThemeRuntimeState.currentThemeID().palette,
            reviewCommentSelectionRouter: nil, reviewCommentSourceContext: nil)
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        body.frame = host.bounds
        host.addSubview(body)
        let ready = await waitForMainActorCondition(timeout: .seconds(5)) {
            host.layoutIfNeeded()
            return (body.virtualizationDiagnosticsForTesting()?.mountedUTF16Count ?? 0) > 0
        }
        #expect(ready)
        let collection = try #require(body.subviews.compactMap { $0 as? UICollectionView }.first)
        body.scrollViewWillBeginDragging(collection)
        collection.setContentOffset(CGPoint(x: 0, y: collection.contentSize.height / 2), animated: false)
        host.layoutIfNeeded()
        #expect(Self.visibleTextViews(in: collection).contains { !$0.textStorage.string.isEmpty },
            "A newly mounted bounded chunk must be readable before yielding to cache warmup")
        let midpointPainted = await waitForMainActorCondition(timeout: .seconds(5)) {
            host.layoutIfNeeded()
            return (body.virtualizationDiagnosticsForTesting()?.mountedUTF16Count ?? 0) > 0
                && Self.visibleTextViews(in: collection).contains { $0.textStorage.string.contains("line ") }
        }
        #expect(midpointPainted)
        let before = try #require(body.virtualizationDiagnosticsForTesting())
        let offset = collection.contentOffset.y
        stream.update(output: first + "pending", command: nil, isDone: false)
        let latest = first + "pending\r\u{1B}[2Kcomplete\n" + String(repeating: "after\n", count: 20_000)
        stream.update(output: latest, command: nil, isDone: false)
        // These synchronous observations catch unmounting/cancel-on-every-delta,
        // before either worker can commit a replacement index.
        #expect(body.virtualizationDiagnosticsForTesting()?.chunkCount == before.chunkCount)
        #expect(body.virtualizationDiagnosticsForTesting()?.mountedUTF16Count ?? 0 > 0)
        var blankBeforeLatest = false
        let rebuilt = await waitForMainActorCondition(timeout: .seconds(5)) {
            host.layoutIfNeeded()
            guard let diagnostics = body.virtualizationDiagnosticsForTesting() else { return false }
            let readable = Self.visibleTextViews(in: collection).contains { $0.textStorage.string.contains("line ") }
            if diagnostics.chunkCount <= before.chunkCount, !readable { blankBeforeLatest = true }
            return diagnostics.chunkCount > before.chunkCount && readable
        }
        #expect(rebuilt)
        #expect(!blankBeforeLatest, "The mounted reader must remain readable between coalesced commits")
        #expect(abs(collection.contentOffset.y - offset) < 1)
        collection.setContentOffset(CGPoint(x: 0, y: max(0, collection.contentSize.height - collection.bounds.height)), animated: false)
        let tailPainted = await waitForMainActorCondition(timeout: .seconds(5)) {
            host.layoutIfNeeded()
            return Self.visibleTextViews(in: collection).contains { $0.textStorage.string.contains("after") }
        }
        #expect(tailPainted)
        #expect(body.virtualizationDiagnosticsForTesting()?.cachedChunkCount ?? 100 <= 14)
        #expect(await body.resolvedCopyText() == first + "complete\n" + String(repeating: "after\n", count: 20_000))
    }

    @Test func coldReaderPaintsIntermediateIndexWhileLargerReplayRuns() async throws {
        let first = String(repeating: "cold line\n", count: 20_000)
        let latest = first + String(repeating: "later line\n", count: 100_000) + "final marker\n"
        let stream = TerminalTraceStream(output: first, command: nil, isDone: false)
        let body = NativeFullScreenTerminalBody(content: first, command: nil, stream: stream,
            palette: ThemeRuntimeState.currentThemeID().palette,
            reviewCommentSelectionRouter: nil, reviewCommentSourceContext: nil)
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        body.frame = host.bounds
        host.addSubview(body)
        host.layoutIfNeeded()
        // Queue the larger successor before the actor yields to the first worker.
        stream.update(output: latest, command: nil, isDone: false)
        let collection = try #require(body.subviews.compactMap { $0 as? UICollectionView }.first)
        let intermediatePainted = await waitForMainActorCondition(timeout: .seconds(5)) {
            host.layoutIfNeeded()
            guard let diagnostics = body.virtualizationDiagnosticsForTesting() else { return false }
            // Coarse disjoint sizes distinguish the two indexes, not exact
            // chunking. No command cell can masquerade as output paint.
            return diagnostics.retainedSourceUTF8Count == latest.utf8.count
                && diagnostics.chunkCount > 0 && diagnostics.chunkCount < 500
                && Self.visibleTextViews(in: collection).contains { $0.textStorage.string.contains("cold line") }
        }
        #expect(intermediatePainted, "A queued successor must not starve initial output paint")
        let latestPainted = await waitForMainActorCondition(timeout: .seconds(5)) {
            host.layoutIfNeeded()
            return Self.visibleTextViews(in: collection).contains { $0.textStorage.string.contains("final marker") }
        }
        #expect(latestPainted)
        #expect(body.virtualizationDiagnosticsForTesting()?.cachedChunkCount ?? 100 <= 14)
    }

    @Test func copyInterpretsCompleteSidecarAsOneTerminal() async throws {
        let first = "head\n\u{1B}[32mpending\n"
        let rest = "\u{1B}[1A\r\u{1B}[2Kcomplete\u{1B}[0m\n"
        let total = (first + rest).utf8.count
        let source = ToolOutputSidecarWindowSource(
            loadFirst: { .init(text: first, endByteOffset: first.utf8.count, totalBytes: total) },
            loadNext: { offset in
                offset == first.utf8.count ? .init(text: rest, endByteOffset: total, totalBytes: total) : nil
            })
        let body = NativeFullScreenTerminalBody(content: first, command: "bash", stream: nil,
            palette: ThemeRuntimeState.currentThemeID().palette,
            reviewCommentSelectionRouter: nil, reviewCommentSourceContext: nil, sidecarSource: source)
        #expect(await body.resolvedCopyText() == "head\ncomplete\n")
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        body.frame = host.bounds
        host.addSubview(body)
        let painted = await waitForMainActorCondition(timeout: .seconds(5)) {
            host.layoutIfNeeded()
            return Self.textViews(in: body).contains { $0.textStorage.string.contains("head\ncomplete") }
        }
        #expect(painted)
        #expect(!Self.textViews(in: body).contains { $0.textStorage.string.contains("pending") })
    }

    @Test func fullScreenCopyButtonUsesResolvedOutput() async throws {
        let raw = "working 10%\r\u{1B}[2K\u{1B}[32mworking 100%\u{1B}[0m\n"
        let controller = FullScreenCodeViewController(
            content: .terminal(content: raw, command: "bash", stream: nil, sidecarSource: nil))
        controller.loadViewIfNeeded()
        var copied: String?
        FullScreenCopyDestination.testWriteOverride = { copied = $0 }
        defer { FullScreenCopyDestination.testWriteOverride = nil }
        _ = controller.perform(Selector("copyTapped"))
        let wrote = await waitForMainActorCondition(timeout: .seconds(3)) { copied != nil }
        #expect(wrote)
        #expect(copied == "working 100%\n")
    }

    private static func visibleTextViews(in collection: UICollectionView) -> [UITextView] {
        collection.visibleCells.flatMap { textViews(in: $0) }
    }

    private static func textViews(in view: UIView) -> [UITextView] {
        (view as? UITextView).map { [$0] } ?? view.subviews.flatMap { textViews(in: $0) }
    }
}
