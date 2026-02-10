import Foundation
import os.log

private let logger = Logger(subsystem: "dev.chenda.PiRemote", category: "Cache")

/// Cached trace snapshot for a session.
struct CachedTrace: Codable, Sendable {
    let sessionId: String
    let eventCount: Int
    let lastEventId: String?
    let savedAt: Date
    let events: [TraceEvent]
}

/// Local disk cache for server responses.
///
/// Stores session traces, session list, workspaces, and skills in
/// `Library/Caches/`. iOS can evict under storage pressure (correct
/// behavior — this is a cache, not persistent state).
///
/// All disk I/O runs on the actor's serial executor, off the main thread.
/// Decode failures return nil (cache miss), never crash.
actor TimelineCache {
    static let shared = TimelineCache()

    private let root: URL
    private let tracesDir: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        root = caches.appending(path: "dev.chenda.PiRemote")
        tracesDir = root.appending(path: "traces")
        encoder = JSONEncoder()
        decoder = JSONDecoder()

        // Ensure directories exist
        try? FileManager.default.createDirectory(at: tracesDir, withIntermediateDirectories: true)
    }

    // MARK: - Trace (per session)

    func loadTrace(_ sessionId: String) -> CachedTrace? {
        let url = traceURL(sessionId)
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            let cached = try decoder.decode(CachedTrace.self, from: data)
            logger.debug("Cache hit: trace for \(sessionId) (\(cached.eventCount) events)")
            return cached
        } catch {
            logger.warning("Cache decode failed for trace \(sessionId): \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: url)
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
            logger.debug("Cache saved: trace for \(sessionId) (\(events.count) events, \(data.count) bytes)")
        } catch {
            logger.warning("Cache write failed for trace \(sessionId): \(error.localizedDescription)")
        }
    }

    func removeTrace(_ sessionId: String) {
        try? FileManager.default.removeItem(at: traceURL(sessionId))
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

    // MARK: - Skills

    func loadSkills() -> [SkillInfo]? {
        load([SkillInfo].self, from: "skills.json")
    }

    func saveSkills(_ skills: [SkillInfo]) {
        save(skills, to: "skills.json")
    }

    // MARK: - Skill Detail

    func loadSkillDetail(_ name: String) -> SkillDetail? {
        load(SkillDetail.self, from: "skills/\(name).json")
    }

    func saveSkillDetail(_ name: String, detail: SkillDetail) {
        let dir = root.appending(path: "skills")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        save(detail, to: "skills/\(name).json")
    }

    // MARK: - Cleanup

    /// Remove trace caches for sessions that no longer exist.
    func evictStaleTraces(keepIds: Set<String>) {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: tracesDir,
            includingPropertiesForKeys: nil
        ) else { return }

        var evicted = 0
        for url in contents {
            let sessionId = url.deletingPathExtension().lastPathComponent
            if !keepIds.contains(sessionId) {
                try? FileManager.default.removeItem(at: url)
                evicted += 1
            }
        }
        if evicted > 0 {
            logger.info("Cache evicted \(evicted) stale trace(s)")
        }
    }

    /// Clear all cached data.
    func clear() {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.createDirectory(at: tracesDir, withIntermediateDirectories: true)
        logger.info("Cache cleared")
    }

    // MARK: - Private

    private func traceURL(_ sessionId: String) -> URL {
        tracesDir.appending(path: "\(sessionId).json")
    }

    private func load<T: Decodable>(_ type: T.Type, from filename: String) -> T? {
        let url = root.appending(path: filename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            let value = try decoder.decode(type, from: data)
            logger.debug("Cache hit: \(filename)")
            return value
        } catch {
            logger.warning("Cache decode failed for \(filename): \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }

    private func save<T: Encodable>(_ value: T, to filename: String) {
        let url = root.appending(path: filename)
        do {
            let data = try encoder.encode(value)
            try data.write(to: url, options: .atomic)
            logger.debug("Cache saved: \(filename) (\(data.count) bytes)")
        } catch {
            logger.warning("Cache write failed for \(filename): \(error.localizedDescription)")
        }
    }
}
