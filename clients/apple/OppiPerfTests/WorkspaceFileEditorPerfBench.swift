import Foundation
import Testing
import UIKit
@testable import Oppi

/// Keystroke-path bench for the workspace file editor.
///
/// Measures one typed character into the continuous UIKit `UITextView`
/// (`insertText` + delegate + `WorkspaceFileEditSession.noteEdit`, then a
/// layout pass) on a 1 MiB file, and the idle checkpoint that encodes the
/// buffer and writes the protected draft. The network is not on either path.
///
/// Simulator numbers are a regression signal only. Device p95 stays a manual
/// check on hardware.
@Suite("Workspace File Editor Perf Bench", .tags(.perf))
@MainActor
struct WorkspaceFileEditorPerfBench {
    private static func source(bytes target: Int) -> String {
        var lines: [String] = []
        var size = 0
        var index = 0
        while size < target - 128 {
            let line = "let value\(index) = compute(\(index), \"payload \(index)\") // line \(index)"
            lines.append(line)
            size += line.utf8.count + 1
            index += 1
        }
        return lines.joined(separator: "\n")
    }

    private static func percentile(_ values: [Double], _ p: Double) -> Double {
        let sorted = values.sorted()
        let rank = Int((Double(sorted.count - 1) * p).rounded())
        return sorted[rank]
    }

    private final class NoopTransport {
        static let transport = WorkspaceFileEditTransport(
            read: { _ in .failed },
            write: { _, _, _ in .notSent }
        )
    }

    private func makeEditor(text: String) -> (WorkspaceFileEditorViewController, UIWindow, WorkspaceFileDraftStore) {
        let store = WorkspaceFileDraftStore(
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("editor-bench-\(UUID().uuidString)", isDirectory: true)
        )
        let session = WorkspaceFileEditSession(
            identity: WorkspaceFileEditIdentity(serverId: "bench", workspaceId: "w", worktreeId: nil, path: "big.swift"),
            disk: WorkspaceFileDiskSnapshot(bytes: Data(text.utf8), etag: "\"sha256-\(String(repeating: "0", count: 64))\""),
            maxBytes: 1_048_576,
            transport: NoopTransport.transport,
            draftStore: store,
            idleDelay: .seconds(3_600)
        )!
        let controller = WorkspaceFileEditorViewController(session: session, themeID: .dark) { _ in UIViewController() }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        return (controller, window, store)
    }

    @Test("Benchmark: keystroke into 1 MiB buffer")
    func keystroke1MiB() {
        let text = Self.source(bytes: 1_048_576)
        let (controller, window, _) = makeEditor(text: text)
        defer { window.isHidden = true }
        let textView = controller.textView
        #expect(textView.becomeFirstResponder())
        // Mid-document caret, visible viewport.
        let middle = (textView.text as NSString).length / 2
        textView.selectedRange = NSRange(location: middle, length: 0)
        textView.scrollRangeToVisible(textView.selectedRange)
        controller.view.layoutIfNeeded()

        for _ in 0..<10 { textView.insertText("w") }
        var samples: [Double] = []
        for index in 0..<200 {
            let character = index % 20 == 19 ? "\n" : "x"
            let start = DispatchTime.now().uptimeNanoseconds
            textView.insertText(character)
            textView.layoutIfNeeded()
            let end = DispatchTime.now().uptimeNanoseconds
            samples.append(Double(end &- start) / 1_000_000)
        }
        let p50 = Self.percentile(samples, 0.5)
        let p95 = Self.percentile(samples, 0.95)
        print(String(format: "METRIC editor_keystroke_1mib_p50_ms=%.3f", p50))
        print(String(format: "METRIC editor_keystroke_1mib_p95_ms=%.3f", p95))
        #expect(controller.session.status == .pending)
        #expect(p95 < 16.7, "keystroke p95 \(p95)ms exceeds one 60 Hz frame")
    }

    @Test("Benchmark: idle checkpoint of 1 MiB draft")
    func checkpoint1MiB() {
        let text = Self.source(bytes: 1_048_576)
        let (controller, window, store) = makeEditor(text: text)
        defer { window.isHidden = true }
        controller.textView.becomeFirstResponder()
        controller.textView.insertText("x")
        var samples: [Double] = []
        for _ in 0..<15 {
            let start = DispatchTime.now().uptimeNanoseconds
            controller.session.checkpoint()
            let end = DispatchTime.now().uptimeNanoseconds
            samples.append(Double(end &- start) / 1_000_000)
        }
        let p50 = Self.percentile(samples, 0.5)
        let p95 = Self.percentile(samples, 0.95)
        print(String(format: "METRIC editor_checkpoint_1mib_p50_ms=%.3f", p50))
        print(String(format: "METRIC editor_checkpoint_1mib_p95_ms=%.3f", p95))
        #expect(store.load(controller.session.identity) != nil)
        #expect(p95 < 100, "checkpoint p95 \(p95)ms")
    }

    @Test("Benchmark: open 1 MiB file into the editor")
    func open1MiB() {
        let text = Self.source(bytes: 1_048_576)
        let start = DispatchTime.now().uptimeNanoseconds
        let (_, window, _) = makeEditor(text: text)
        let end = DispatchTime.now().uptimeNanoseconds
        window.isHidden = true
        let ms = Double(end &- start) / 1_000_000
        print(String(format: "METRIC editor_open_1mib_ms=%.3f", ms))
        #expect(ms < 2_000, "open \(ms)ms")
    }
}
