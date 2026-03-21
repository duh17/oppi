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

@MainActor
final class SourceTraceStream {
    struct Snapshot {
        let text: String
        let filePath: String?
        let isDone: Bool
        let finalContent: FullScreenCodeContent?
    }

    private var snapshotStorage: Snapshot
    private var observers: [UUID: (Snapshot) -> Void] = [:]

    init(text: String, filePath: String?, isDone: Bool, finalContent: FullScreenCodeContent?) {
        snapshotStorage = Snapshot(
            text: text,
            filePath: filePath,
            isDone: isDone,
            finalContent: finalContent
        )
    }

    // periphery:ignore
    var snapshot: Snapshot {
        snapshotStorage
    }

    func update(text: String, filePath: String?, isDone: Bool, finalContent: FullScreenCodeContent?) {
        let next = Snapshot(
            text: text,
            filePath: filePath,
            isDone: isDone,
            finalContent: finalContent
        )
        guard shouldNotify(for: next) else { return }

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

    private func shouldNotify(for next: Snapshot) -> Bool {
        next.text != snapshotStorage.text
            || next.filePath != snapshotStorage.filePath
            || next.isDone != snapshotStorage.isDone
            || finalContentKind(next.finalContent) != finalContentKind(snapshotStorage.finalContent)
    }

    private func finalContentKind(_ content: FullScreenCodeContent?) -> String? {
        switch content {
        case .code:
            return "code"
        case .plainText:
            return "plainText"
        case .diff:
            return "diff"
        case .markdown:
            return "markdown"
        case .html:
            return "html"
        case .thinking:
            return "thinking"
        case .terminal:
            return "terminal"
        case .liveSource:
            return "liveSource"
        case nil:
            return nil
        }
    }
}

/// Full-screen content viewer for tool output.
///
/// Supports three modes:
/// - `.code`: syntax-highlighted source with line numbers
/// - `.diff`: unified diff with add/remove coloring
/// - `.markdown`: full markdown note/reader rendering
indirect enum FullScreenCodeContent {
    case code(content: String, language: String?, filePath: String?, startLine: Int)
    case plainText(content: String, filePath: String?)
    case diff(oldText: String, newText: String, filePath: String?, precomputedLines: [DiffLine]?)
    case markdown(content: String, filePath: String?)
    case html(content: String, filePath: String?)
    case thinking(content: String, stream: ThinkingTraceStream? = nil)
    case terminal(content: String, command: String?, stream: TerminalTraceStream? = nil)
    case liveSource(snapshot: SourceTraceStream.Snapshot, stream: SourceTraceStream)
}

/// SwiftUI wrapper around ``FullScreenCodeViewController``.
///
/// Used by `.fullScreenCover` in `FileContentView`, `MarkdownText`,
/// and `DiffContentView`. All rendering is UIKit.
struct FullScreenCodeView: UIViewControllerRepresentable {
    let content: FullScreenCodeContent
    let selectedTextPiRouter: SelectedTextPiActionRouter?
    let selectedTextSessionId: String?
    let selectedTextSourceLabel: String?

    init(
        content: FullScreenCodeContent,
        selectedTextPiRouter: SelectedTextPiActionRouter? = nil,
        selectedTextSessionId: String? = nil,
        selectedTextSourceLabel: String? = nil
    ) {
        self.content = content
        self.selectedTextPiRouter = selectedTextPiRouter
        self.selectedTextSessionId = selectedTextSessionId
        self.selectedTextSourceLabel = selectedTextSourceLabel
    }

    func makeUIViewController(context: Context) -> FullScreenCodeViewController {
        FullScreenCodeViewController(
            content: content,
            selectedTextPiRouter: selectedTextPiRouter,
            selectedTextSessionId: selectedTextSessionId,
            selectedTextSourceLabel: selectedTextSourceLabel
        )
    }

    func updateUIViewController(_ uiViewController: FullScreenCodeViewController, context: Context) {
        // Content is immutable — nothing to update.
    }
}
