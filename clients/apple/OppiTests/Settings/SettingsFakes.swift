import Foundation
import Testing
@testable import Oppi

/// Holds an async call until the test lets it through.
actor SettingsGate {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func open() {
        isOpen = true
        for continuation in waiting { continuation.resume() }
        waiting = []
    }
}

/// A second setting on the Server Metrics route, for the tests that need two
/// settings sharing one document (the route has only `enabled` in the app).
let testLabelSetting = SettingDeclaration<String>(
    id: "test.label", key: "label", storage: .server(.serverMetrics, revisioned: true), default: "",
    validate: { $0.trimmingCharacters(in: .whitespaces).isEmpty ? "Give it a label." : nil },
    copy: SettingCopy(title: "Label")
)

/// A server settings route kept in memory: it records every call, can be held,
/// and can fail on demand. A `nil` revision answers documents with no revision,
/// like a route that does not revision its settings.
final class FakeSettingsTransport: SettingsServerTransport, @unchecked Sendable {
    struct Save: Equatable {
        var endpoint: SettingEndpoint
        var fields: [String: JSONValue]
        var baseRevision: Int?
    }

    private let lock = NSLock()
    private var document: SettingsServerDocument
    private var _loads = 0
    private var _saves: [Save] = []
    private var saveErrors: [Error] = []
    private var loadErrors: [Error] = []
    private var loadAnswers: [SettingsServerDocument] = []
    private var saveGate: SettingsGate?
    private var loadGate: SettingsGate?
    private var beforeSave: [() -> Void] = []
    private let revisioned: Bool

    init(fields: [String: JSONValue] = ["enabled": false, "label": "first"], revision: Int? = 4) {
        document = SettingsServerDocument(fields: fields, revision: revision)
        revisioned = revision != nil
    }

    var loads: Int { lock.withLock { _loads } }
    var saves: [Save] { lock.withLock { _saves } }

    /// The next save throws `error`.
    func failNextSave(with error: Error) { lock.withLock { saveErrors.append(error) } }
    func failNextLoad(with error: Error) { lock.withLock { loadErrors.append(error) } }
    /// The next load answers `document` instead of the route's own, as an answer that arrives late would.
    func answerNextLoad(with document: SettingsServerDocument) { lock.withLock { loadAnswers.append(document) } }
    func holdSaves(_ gate: SettingsGate) { lock.withLock { saveGate = gate } }
    func holdLoads(_ gate: SettingsGate) { lock.withLock { loadGate = gate } }
    /// Runs `action` as the next save arrives, before the server checks its revision:
    /// a change that lands between a caller's last read and its write.
    func beforeNextSave(_ action: @escaping () -> Void) { lock.withLock { beforeSave.append(action) } }
    /// Another device changed the document.
    func changeElsewhere(_ fields: [String: JSONValue]) {
        lock.withLock {
            for (key, value) in fields { document.fields[key] = value }
            if let revision = document.revision { document.revision = revision + 1 }
        }
    }

    func loadSettings(_ endpoint: SettingEndpoint) async throws -> SettingsServerDocument {
        let (gate, error, snapshot) = lock.withLock {
            _loads += 1
            return (loadGate, loadErrors.isEmpty ? nil : loadErrors.removeFirst(), loadAnswers.isEmpty ? document : loadAnswers.removeFirst())
        }
        await gate?.wait()
        if let error { throw error }
        return snapshot
    }

    func saveSettings(
        _ endpoint: SettingEndpoint,
        fields: [String: JSONValue],
        baseRevision: Int?
    ) async throws -> SettingsServerDocument {
        let (gate, error, hook) = lock.withLock {
            _saves.append(Save(endpoint: endpoint, fields: fields, baseRevision: baseRevision))
            return (saveGate, saveErrors.isEmpty ? nil : saveErrors.removeFirst(), beforeSave.isEmpty ? nil : beforeSave.removeFirst())
        }
        hook?()
        await gate?.wait()
        if let error { throw error }
        return try lock.withLock {
            if revisioned, let baseRevision, baseRevision != document.revision {
                throw SettingsError.revisionConflict
            }
            for (key, value) in fields { document.fields[key] = value }
            if let revision = document.revision { document.revision = revision + 1 }
            return document
        }
    }
}

struct SettingsTestError: LocalizedError {
    var errorDescription: String? { "The server said no." }
}

/// A `UserDefaults` that cannot leak into the app's own.
func makeSettingsDefaults() throws -> UserDefaults {
    let name = "settings-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defaults.removePersistentDomain(forName: name)
    return defaults
}
