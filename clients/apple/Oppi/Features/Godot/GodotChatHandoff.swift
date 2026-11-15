import UIKit

/// The hand-off from a game to the agent beside it: a draft in the chat's
/// composer, never sent, so the person adds words and sends it. The draft
/// names the game and its release, carries the error the pane shows (message,
/// file and line, backtrace) with the log's other recent errors, and has the
/// current frame attached as an image. The error overlay's Ask Agent and the
/// pane's Send Frame to Chat both go through `handOff`.
@MainActor
enum GodotChatHandoff {
    /// How many of the log's other recent errors go with an error.
    static let recentErrorLimit = 5

    /// What a hand-off sends: the game, and the error it is about, if any.
    struct Subject {
        var game: String
        var release: Int?
        var error: GodotEngineLog?
        /// The game's recent log, oldest first (`GodotEngineHost.log`).
        var log: [GodotEngineLog] = []
    }

    /// The chat a hand-off from `pane` goes to, or nil when none can take it.
    static func chat(beside pane: UIViewController) -> ChatViewController? {
        destination(of: pane)?.chat
    }

    /// Puts `subject`'s draft, with `frame` (PNG) attached, into the chat
    /// beside `pane`, and brings that chat into view. False, and nothing
    /// changes, when no chat can take it, or when a hand-off without an error
    /// has no frame to send.
    @discardableResult
    static func handOff(_ subject: Subject, frame: Data?, from pane: UIViewController) -> Bool {
        guard let destination = destination(of: pane) else { return false }
        let image = frame.flatMap { png in UIImage(data: png).map { PendingImage.from(data: png, mimeType: "image/png", image: $0) } }
        guard subject.error != nil || image != nil else { return false }
        destination.show()
        destination.chat.stageInComposer(
            prompt: text(subject, hasFrame: image != nil),
            attachments: image.map { [$0.pendingAttachment] } ?? []
        )
        return true
    }

    /// The draft's words. Without an error, the hand-off is the frame alone.
    static func text(_ subject: Subject, hasFrame: Bool) -> String {
        let game = "Godot game “\(subject.game)”" + (subject.release.map { " (release \($0))" } ?? "")
        guard let error = subject.error else { return "Here is the current frame of the \(game)." }
        var lines = ["The \(game) shows this error:", "", "```", error.message] + places(of: error)
        let trace = error.backtrace.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trace.isEmpty { lines.append(trace) }
        lines.append("```")
        let earlier = subject.log.filter { $0.linkEntry.level == .error && $0 != error }.suffix(recentErrorLimit)
        if !earlier.isEmpty {
            lines += ["", "Recent errors in its log:"]
            lines += earlier.map { entry -> String in
                let at = places(of: entry)
                return "- " + entry.message + (at.isEmpty ? "" : " (\(at.joined(separator: ", ")))")
            }
        }
        if hasFrame { lines += ["", "The current frame is attached."] }
        return lines.joined(separator: "\n")
    }

    /// Where in the game `entry` comes from, as `file:line`: the game file
    /// that raised it (a script that failed to parse), then the script frame
    /// it was raised from (`GodotEngineLog.location`).
    private static func places(of entry: GodotEngineLog) -> [String] {
        let raised = entry.file.hasPrefix("res://") ? "\(entry.file):\(entry.line)" : nil
        let location = entry.location.map { "\($0.file):\($0.line)" }
        return [raised, location == raised ? nil : location].compactMap { $0 }
    }

    /// The chat and how to bring it into view: the chat the pane was pushed
    /// over (a compact window, or no room beside: the chat that opened the
    /// game), else the window's current chat, in the primary's cell of the
    /// pane's host.
    private static func destination(of pane: UIViewController) -> (chat: ChatViewController, show: () -> Void)? {
        if let navigation = pane.navigationController, let index = navigation.viewControllers.firstIndex(of: pane),
           let route = navigation.viewControllers[..<index].last(where: { $0 is ChatRouteViewController }) as? ChatRouteViewController,
           let chat = route.chat {
            return (chat, { [weak navigation, weak route] in
                guard let navigation, let route else { return }
                navigation.popToViewController(route, animated: true)
            })
        }
        guard let host = PaneHostController.containing(pane), let chat = host.routedChat else { return nil }
        return (chat, { [weak host] in host?.showRoutedCell() })
    }
}
