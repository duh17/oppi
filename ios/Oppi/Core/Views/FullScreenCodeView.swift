import SwiftUI
import UIKit

@MainActor
final class ThinkingTraceStream {
    struct Snapshot: Equatable {
        let text: String
        let isDone: Bool
    }

    private var snapshotStorage: Snapshot
    private var observers: [UUID: (Snapshot) -> Void] = [:]

    init(text: String, isDone: Bool) {
        snapshotStorage = Snapshot(text: text, isDone: isDone)
    }

    var snapshot: Snapshot {
        snapshotStorage
    }

    func update(text: String, isDone: Bool) {
        let next = Snapshot(text: text, isDone: isDone)
        guard next != snapshotStorage else { return }

        snapshotStorage = next
        for observer in observers.values {
            observer(next)
        }
    }

    @discardableResult
    func addObserver(deliverImmediately: Bool = true, _ observer: @escaping (Snapshot) -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer
        if deliverImmediately {
            observer(snapshotStorage)
        }
        return id
    }

    func removeObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
    }
}

@MainActor
final class TerminalTraceStream {
    struct Snapshot: Equatable {
        let output: String
        let command: String?
        let isDone: Bool
    }

    private var snapshotStorage: Snapshot
    private var observers: [UUID: (Snapshot) -> Void] = [:]

    init(output: String, command: String?, isDone: Bool) {
        snapshotStorage = Snapshot(output: output, command: command, isDone: isDone)
    }

    var snapshot: Snapshot {
        snapshotStorage
    }

    func update(output: String, command: String?, isDone: Bool) {
        let next = Snapshot(output: output, command: command, isDone: isDone)
        guard next != snapshotStorage else { return }

        snapshotStorage = next
        for observer in observers.values {
            observer(next)
        }
    }

    @discardableResult
    func addObserver(deliverImmediately: Bool = true, _ observer: @escaping (Snapshot) -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer
        if deliverImmediately {
            observer(snapshotStorage)
        }
        return id
    }

    func removeObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
    }
}

/// Full-screen content viewer for tool output.
///
/// Supports three modes:
/// - `.code`: syntax-highlighted source with line numbers
/// - `.diff`: unified diff with add/remove coloring
/// - `.markdown`: full markdown note/reader rendering
enum FullScreenCodeContent {
    case code(content: String, language: String?, filePath: String?, startLine: Int)
    case diff(oldText: String, newText: String, filePath: String?, precomputedLines: [DiffLine]?)
    case markdown(content: String, filePath: String?)
    case thinking(content: String, stream: ThinkingTraceStream? = nil)
    case terminal(content: String, command: String?, stream: TerminalTraceStream? = nil)
}

/// SwiftUI wrapper around ``FullScreenCodeViewController``.
///
/// Used by `.fullScreenCover` in `FileContentView`, `MarkdownText`,
/// and `DiffContentView`. All rendering is UIKit.
struct FullScreenCodeView: UIViewControllerRepresentable {
    let content: FullScreenCodeContent

    func makeUIViewController(context: Context) -> FullScreenCodeViewController {
        FullScreenCodeViewController(content: content)
    }

    func updateUIViewController(_ uiViewController: FullScreenCodeViewController, context: Context) {
        // Content is immutable — nothing to update.
    }
}
