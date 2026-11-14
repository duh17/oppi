#if DEBUG
import CryptoKit
import Foundation

/// The chat-routes server's games, for tests of the Godot pane
/// (`ChatRoutesURLProtocol`). `CHAT_ROUTES_GODOT=1` lists five Godot
/// projects, one per state a pane shows; `CHAT_ROUTES_GODOT=empty` lists none.
/// `CHAT_ROUTES_GODOT_PACK` is the sample's exported pack (base64), which the
/// projects with a build serve:
///
/// - Tide Runner plays the sample. With `CHAT_ROUTES_GODOT_PACK_SETTINGS` (the
///   sample exported with a changed project setting), its player link sends
///   that build as a second release a few seconds after it attaches.
/// - Moss Garden has no build yet.
/// - Star Courier plays the sample with `--probe`, whose script raises errors.
/// - Pocket Dungeon's pack says it was exported by Godot 4.8.
/// - Lantern's pack never finishes downloading.
///
/// Releases are a few minutes to a day old. `CHAT_ROUTES_GODOT_HOT` makes the
/// device critically hot a few seconds after Tide Runner's pane attaches
/// (`GodotEngineHost`).
///
/// Everything else under /godot is a 404. The player link is scripted in
/// process (`playerLink`), since a preview connection has no server socket.
enum ChatRoutesGodot {
    struct Project {
        let id: String
        let name: String
        let label: String?
        let pack: Data?
        let args: [String]?
        /// The pack request never answers: the build stays downloading.
        let packHangs: Bool
        /// The Godot the release names.
        var engineVersion = "4.7"
        /// How long ago the release was made.
        var age: TimeInterval = 5 * 60
    }

    /// When the harness's releases are dated from: this launch.
    private static let launched = Date()

    private static let environment = ProcessInfo.processInfo.environment

    private static let samplePack: Data? = environment["CHAT_ROUTES_GODOT_PACK"].flatMap { Data(base64Encoded: $0) }
    private static let settingsPack: Data? = environment["CHAT_ROUTES_GODOT_PACK_SETTINGS"].flatMap { Data(base64Encoded: $0) }

    /// The sample with its header's Godot minor version raised to 8.
    private static var newerPack: Data? {
        guard var pack = samplePack, pack.count > 16 else { return nil }
        pack[pack.startIndex + 12] = 8
        return pack
    }

    static var projects: [Project] {
        guard environment["CHAT_ROUTES_GODOT"] == "1" else { return [] }
        return [
            Project(id: "tide-runner-3fa9c2b1", name: "Tide Runner", label: "Faster waves", pack: samplePack, args: nil, packHangs: false, age: 3 * 60),
            Project(id: "moss-garden-7c1d2e3f", name: "Moss Garden", label: nil, pack: nil, args: nil, packHangs: false),
            Project(id: "star-courier-9b2e4a10", name: "Star Courier", label: "Cargo bay doors", pack: samplePack, args: ["--probe"], packHangs: false, age: 2 * 3600),
            Project(
                id: "pocket-dungeon-51d0c7e2", name: "Pocket Dungeon", label: "New torch light", pack: newerPack, args: nil, packHangs: false,
                engineVersion: "4.8", age: 26 * 3600
            ),
            Project(id: "lantern-6e8a1f33", name: "Lantern", label: "Night levels", pack: samplePack, args: nil, packHangs: true, age: 5 * 60),
        ]
    }

    private static func engine(_ project: Project) -> [String: Any] { ["name": "godot", "version": project.engineVersion] }

    private static func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func release(_ project: Project, pack: Data, seq: Int, label: String?) -> [String: Any] {
        var release: [String: Any] = [
            "v": 1, "seq": seq, "createdAt": (launched.timeIntervalSince1970 - project.age) * 1000 + Double(seq), "origin": "discovery",
            "engine": engine(project),
            "packs": [["sha256": sha(pack), "size": pack.count, "format": "pck"]],
            "reload": "scripts",
        ]
        if let label { release["label"] = label }
        if let args = project.args { release["entry"] = ["args": args] }
        return release
    }

    /// `GodotProject` as `protocol/godot.json` has it.
    private static func json(_ project: Project) -> [String: Any] {
        var value: [String: Any] = [
            "id": project.id, "name": project.name, "engine": engine(project), "players": [Any](),
            "source": ["workspaceId": "chat-routes-ws", "worktreeId": "main", "checkout": "/tmp/oppi-chat-routes", "root": "games/\(project.id)"],
        ]
        if let pack = project.pack { value["release"] = release(project, pack: pack, seq: 1, label: project.label) }
        return value
    }

    /// The answer to a request under /godot, or nil for any other path.
    /// `hangs`: answer nothing, as a download that never finishes.
    static func answer(_ method: String, _ path: String) -> (body: Data?, contentType: String, hangs: Bool)? {
        guard environment["CHAT_ROUTES_GODOT"] != nil, method == "GET",
              path == "/godot" || path.hasPrefix("/godot/") else { return nil }
        let parts = path.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
        let project = parts.count > 1 ? projects.first { $0.id == parts[1] } : nil
        switch parts.count {
        case 1:
            return (encode(["projects": projects.map(json)]), "application/json", false)
        case 2:
            guard let project else { return (nil, "application/json", false) }
            var detail = json(project)
            detail["releases"] = detail["release"].map { [$0] } ?? []
            detail["logNext"] = 0
            return (encode(detail), "application/json", false)
        case 4 where parts[2] == "packs":
            let packs = [project?.pack, project?.id == "tide-runner-3fa9c2b1" ? settingsPack : nil].compactMap { $0 }
            guard let project, let pack = packs.first(where: { sha($0) == parts[3] }) else { return (nil, "application/json", false) }
            return (pack, "application/octet-stream", project.packHangs)
        default:
            return (nil, "application/json", false)
        }
    }

    // MARK: The player link

    /// The scripted server end of a pane's player link: `attached` once the
    /// pane attaches; for Tide Runner with a settings build, that build as
    /// release 2 three seconds later.
    @MainActor
    static func playerLink(project id: String) -> GodotPlayerLink? {
        guard let project = projects.first(where: { $0.id == id }),
              let url = URL(string: "wss://chat-routes.oppi/godot/\(id)/link?role=player") else { return nil }
        if project.args == ["--probe"] { plantEscapeLink(project: id) }
        return GodotPlayerLink(
            url: url, token: { "preview-token" }, renewer: nil,
            tlsCertFingerprint: nil, tlsServerName: nil, tailnetRoute: .direct,
            webSocketFactory: { _ in ScriptedGodotServer(project: project).transport }
        )
    }

    /// A link in the probe game's `user://` to the app's container, as if
    /// something other than the game had made one: the probe lists through
    /// it ("probe list through link"), which the engine's sandbox refuses.
    @MainActor
    private static func plantEscapeLink(project: String) {
        let user = GodotFolders.user(for: GodotSlot(serverId: PaneRestorePreviewController.serverId, project: project))
        let container = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        try? FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: user.appending(path: "escape"))
        try? FileManager.default.createSymbolicLink(at: user.appending(path: "escape"), withDestinationURL: container)
    }

    /// Player links attached per project this launch.
    @MainActor private static var attachCount: [String: Int] = [:]

    @MainActor
    private final class ScriptedGodotServer {
        private let project: Project
        private var queued: [String] = []
        private var pending: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?
        private var closed = false

        init(project: Project) {
            self.project = project
        }

        lazy var transport = PersistentWebSocketTransport(
            identity: self,
            resume: {},
            // Strong: the transport is all that keeps this end of the link alive.
            receive: { try await self.receive() },
            send: { message in
                guard case .string(let text) = message, text.contains(#""type":"attach""#) else { return }
                self.attached()
            },
            cancel: { _, _ in self.close() },
            response: { nil },
            closeCode: { .invalid }
        )

        private func attached() {
            yield(["type": "attached", "role": "player", "playerId": "player-preview", "project": ChatRoutesGodot.json(project)])
            ChatRoutesGodot.attachCount[project.id, default: 0] += 1
            if project.id == "tide-runner-3fa9c2b1", ChatRoutesGodot.environment["CHAT_ROUTES_GODOT_HOT"] != nil {
                Task { @MainActor in
                    // Once the game plays: the heat pauses a running game.
                    try? await Task.sleep(for: .seconds(6))
                    GodotEngineHost._thermalStateForTesting = .critical
                    NotificationCenter.default.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
                }
            }
            if project.id == "tide-runner-3fa9c2b1", ChatRoutesGodot.attachCount[project.id] == 2 {
                // An agent's `run` reaches the pane that attached last: a
                // second pane on a running game. It must leave the game where it plays.
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(1))
                    self?.yield(["type": "command", "id": "run-1", "command": ["name": "run"], "timeoutMs": 5000])
                }
            }
            guard project.id == "tide-runner-3fa9c2b1", let settings = ChatRoutesGodot.settingsPack else { return }
            let release = ChatRoutesGodot.release(project, pack: settings, seq: 2, label: "Wider screens")
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(3))
                self?.yield(["type": "release", "release": release])
            }
        }

        private func yield(_ message: [String: Any]) {
            guard let data = ChatRoutesGodot.encode(message), let text = String(data: data, encoding: .utf8) else { return }
            if let pending {
                self.pending = nil
                pending.resume(returning: .string(text))
            } else {
                queued.append(text)
            }
        }

        private func receive() async throws -> URLSessionWebSocketTask.Message {
            if closed { throw URLError(.cancelled) }
            if !queued.isEmpty { return .string(queued.removeFirst()) }
            return try await withCheckedThrowingContinuation { pending = $0 }
        }

        private func close() {
            closed = true
            pending?.resume(throwing: URLError(.cancelled))
            pending = nil
        }
    }

    fileprivate static func encode(_ object: Any) -> Data? {
        try? JSONSerialization.data(withJSONObject: object)
    }
}
#endif
