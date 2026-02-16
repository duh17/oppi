import Foundation
import os.log

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "Cache")

/// Cached trace snapshot for a session.
struct CachedTrace: Codable, Sendable {
    let sessionId: String
    let eventCount: Int
    let lastEventId: String?
    let savedAt: Date
    let events: [TraceEvent]
}

/// Aggregate cache telemetry for diagnostics.
struct TimelineCacheMetrics: Sendable {
    let rootPath: String
    let hits: Int
    let misses: Int
    let decodeFailures: Int
    let writes: Int
    let averageLoadMs: Int
}

/// Local disk cache for server responses.
///
/// Stores session traces, session list, workspaces, and skills under
/// `Library/Application Support/` for durable read continuity.
///
/// All disk I/O runs on the actor's serial executor, off the main thread.
/// Decode failures return nil (cache miss), never crash.
actor TimelineCache {
    static let shared = TimelineCache()

    private let fileManager: FileManager
    private let root: URL
    private let tracesDir: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    // Telemetry (best-effort, process-local)
    private var hitCount = 0
    private var missCount = 0
    private var decodeFailureCount = 0
    private var writeCount = 0
    private var totalLoadMs = 0
    private var loadSamples = 0

    init(
        rootURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager

        let resolvedRoot = rootURL ?? Self.defaultRootURL(fileManager: fileManager)
        root = resolvedRoot
        tracesDir = resolvedRoot.appending(path: "traces", directoryHint: .isDirectory)

        // Ensure directories exist
        try? fileManager.createDirectory(at: tracesDir, withIntermediateDirectories: true)

        encoder = JSONEncoder()
        decoder = JSONDecoder()

        logger.notice("Cache root initialized at \(self.root.path, privacy: .public)")
    }

    // MARK: - Trace (per session)

    func loadTrace(_ sessionId: String) -> CachedTrace? {
        let startedAt = Date()
        var hit = false
        defer { recordLoad(startedAt: startedAt, hit: hit) }

        let url = traceURL(sessionId)
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            let cached = try decoder.decode(CachedTrace.self, from: data)
            hit = true
            logger.debug("Cache hit: trace for \(sessionId) (\(cached.eventCount) events)")
            return cached
        } catch {
            decodeFailureCount += 1
            logger.warning("Cache decode failed for trace \(sessionId): \(error.localizedDescription)")
            try? fileManager.removeItem(at: url)
            return nil
        }
    }

    func saveTrace(_ sessionId: String, events: [TraceEvent]) {
        let cached = CachedTrace(
            sessionId: sessionId,
            eventCount: events.count,
            lastEventId: events.last?.id,
            savedAt: Date(),
            events: events
        )
        do {
            let data = try encoder.encode(cached)
            try data.write(to: traceURL(sessionId), options: .atomic)
            writeCount += 1
            logger.debug("Cache saved: trace for \(sessionId) (\(events.count) events, \(data.count) bytes)")
        } catch {
            logger.warning("Cache write failed for trace \(sessionId): \(error.localizedDescription)")
        }
    }

    func removeTrace(_ sessionId: String) {
        try? fileManager.removeItem(at: traceURL(sessionId))
        logger.debug("Cache removed: trace for \(sessionId)")
    }

    // MARK: - Session List

    func loadSessionList() -> [Session]? {
        load([Session].self, from: "session-list.json")
    }

    func saveSessionList(_ sessions: [Session]) {
        save(sessions, to: "session-list.json")
    }

    // MARK: - Workspaces

    func loadWorkspaces() -> [Workspace]? {
        load([Workspace].self, from: "workspaces.json")
    }

    func saveWorkspaces(_ workspaces: [Workspace]) {
        save(workspaces, to: "workspaces.json")
    }

    /// Load workspaces for a specific server (multi-server).
    func loadWorkspaces(serverId: String) -> [Workspace]? {
        ensureServerDir(serverId)
        return load([Workspace].self, from: serverPath(serverId, "workspaces.json"))
    }

    /// Save workspaces for a specific server (multi-server).
    func saveWorkspaces(_ workspaces: [Workspace], serverId: String) {
        ensureServerDir(serverId)
        save(workspaces, to: serverPath(serverId, "workspaces.json"))
    }

    // MARK: - Skills

    func loadSkills() -> [SkillInfo]? {
        load([SkillInfo].self, from: "skills.json")
    }

    func saveSkills(_ skills: [SkillInfo]) {
        save(skills, to: "skills.json")
    }

    /// Load skills for a specific server (multi-server).
    func loadSkills(serverId: String) -> [SkillInfo]? {
        ensureServerDir(serverId)
        return load([SkillInfo].self, from: serverPath(serverId, "skills.json"))
    }

    /// Save skills for a specific server (multi-server).
    func saveSkills(_ skills: [SkillInfo], serverId: String) {
        ensureServerDir(serverId)
        save(skills, to: serverPath(serverId, "skills.json"))
    }

    // MARK: - Skill Detail

    func loadSkillDetail(_ name: String) -> SkillDetail? {
        load(SkillDetail.self, from: "skills/\(name).json")
    }

    func saveSkillDetail(_ name: String, detail: SkillDetail) {
        let dir = root.appending(path: "skills")
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        save(detail, to: "skills/\(name).json")
    }

    // MARK: - Telemetry

    func metrics() -> TimelineCacheMetrics {
        let avgLoadMs = loadSamples > 0 ? (totalLoadMs / loadSamples) : 0
        return TimelineCacheMetrics(
            rootPath: root.path,
            hits: hitCount,
            misses: missCount,
            decodeFailures: decodeFailureCount,
            writes: writeCount,
            averageLoadMs: avgLoadMs
        )
    }

    // MARK: - Cleanup

    /// Remove trace caches for sessions that no longer exist.
    func evictStaleTraces(keepIds: Set<String>) {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: tracesDir,
            includingPropertiesForKeys: nil
        ) else { return }

        var evicted = 0
        for url in contents {
            let sessionId = url.deletingPathExtension().lastPathComponent
            if !keepIds.contains(sessionId) {
                try? fileManager.removeItem(at: url)
                evicted += 1
            }
        }
        if evicted > 0 {
            logger.info("Cache evicted \(evicted) stale trace(s)")
        }
    }

    /// Clear all cached data.
    func clear() {
        try? fileManager.removeItem(at: root)
        try? fileManager.createDirectory(at: tracesDir, withIntermediateDirectories: true)

        hitCount = 0
        missCount = 0
        decodeFailureCount = 0
        writeCount = 0
        totalLoadMs = 0
        loadSamples = 0

        logger.info("Cache cleared")
    }

    // MARK: - Private

    private static func defaultRootURL(fileManager: FileManager) -> URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let appRoot = appSupport.appending(path: AppIdentifiers.subsystem, directoryHint: .isDirectory)
        return appRoot.appending(path: "cache", directoryHint: .isDirectory)
    }

    private func traceURL(_ sessionId: String) -> URL {
        tracesDir.appending(path: "\(sessionId).json")
    }

    /// Path for a server-namespaced file: `servers/<id>/<filename>`.
    private func serverPath(_ serverId: String, _ filename: String) -> String {
        "servers/\(serverId)/\(filename)"
    }

    /// Ensure the server subdirectory exists.
    private func ensureServerDir(_ serverId: String) {
        let dir = root.appending(path: "servers/\(serverId)", directoryHint: .isDirectory)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func load<T: Decodable>(_ type: T.Type, from filename: String) -> T? {
        let startedAt = Date()
        var hit = false
        defer { recordLoad(startedAt: startedAt, hit: hit) }

        let url = root.appending(path: filename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            let value = try decoder.decode(type, from: data)
            hit = true
            logger.debug("Cache hit: \(filename)")
            return value
        } catch {
            decodeFailureCount += 1
            logger.warning("Cache decode failed for \(filename): \(error.localizedDescription)")
            try? fileManager.removeItem(at: url)
            return nil
        }
    }

    private func save<T: Encodable>(_ value: T, to filename: String) {
        let url = root.appending(path: filename)
        do {
            let data = try encoder.encode(value)
            try data.write(to: url, options: .atomic)
            writeCount += 1
            logger.debug("Cache saved: \(filename) (\(data.count) bytes)")
        } catch {
            logger.warning("Cache write failed for \(filename): \(error.localizedDescription)")
        }
    }

    private func recordLoad(startedAt: Date, hit: Bool) {
        let elapsedMs = max(0, Int((Date().timeIntervalSince(startedAt) * 1_000.0).rounded()))
        if hit {
            hitCount += 1
        } else {
            missCount += 1
        }
        totalLoadMs += elapsedMs
        loadSamples += 1
    }
}
