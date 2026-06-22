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
/// Stores session traces, server-scoped session lists, workspaces, and skills
/// under `Library/Application Support/` for durable read continuity.
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

    /// Avoid MetricKit disk-write exceptions from caching very large active traces.
    private static let maxTraceCacheBytes = 8 * 1024 * 1024

    // periphery:ignore - lets tests build an oversized fixture from the production cap
    static var maxTraceCacheBytesForTesting: Int { maxTraceCacheBytes }

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

        logger.notice("Cache root initialized at \(self.root.lastPathComponent, privacy: .public)")
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
        do {
            let url = traceURL(sessionId)
            if let existingData = try? Data(contentsOf: url),
               let existing = try? decoder.decode(CachedTrace.self, from: existingData),
               existing.events == events {
                logger.debug("Cache unchanged: trace for \(sessionId) (\(events.count) events, \(existingData.count) bytes)")
                return
            }

            let estimatedBytes = estimatedTracePayloadBytes(events)
            guard estimatedBytes <= Self.maxTraceCacheBytes else {
                removeOversizedTraceCache(url: url, sessionId: sessionId, eventCount: events.count, bytes: estimatedBytes)
                return
            }

            let cached = CachedTrace(
                sessionId: sessionId,
                eventCount: events.count,
                lastEventId: events.last?.id,
                savedAt: Date(),
                events: events
            )
            let data = try encoder.encode(cached)
            guard data.count <= Self.maxTraceCacheBytes else {
                removeOversizedTraceCache(url: url, sessionId: sessionId, eventCount: events.count, bytes: data.count)
                return
            }

            try data.write(to: url, options: .atomic)
            writeCount += 1
            logger.debug("Cache saved: trace for \(sessionId) (\(events.count) events, \(data.count) bytes)")
        } catch {
            logger.warning("Cache write failed for trace \(sessionId): \(error.localizedDescription)")
        }
    }

    // periphery:ignore - used by ChatSessionManagerTests via @testable import
    func removeTrace(_ sessionId: String) {
        try? fileManager.removeItem(at: traceURL(sessionId))
        logger.debug("Cache removed: trace for \(sessionId)")
    }

    // MARK: - Session List

    /// Legacy single-server session-list cache.
    func loadSessionList() -> [Session]? {
        load([Session].self, from: "session-list.json")
    }

    /// Load the recent session projection for a specific server.
    func loadSessionList(serverId: String) -> [Session]? {
        ensureServerDir(serverId)
        return load([Session].self, from: serverPath(serverId, "session-list.json"))
    }

    /// Save the recent session projection for a specific server.
    func saveSessionList(_ sessions: [Session], serverId: String) {
        ensureServerDir(serverId)
        save(sessions, to: serverPath(serverId, "session-list.json"))
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

    // MARK: - Disk Size

    /// Total bytes consumed by all cached files under the cache root.
    func diskSize() -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let size = values.fileSize
            else { continue }
            total += Int64(size)
        }
        return total
    }

    // MARK: - Cleanup

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

    private func removeOversizedTraceCache(url: URL, sessionId: String, eventCount: Int, bytes: Int) {
        try? fileManager.removeItem(at: url)
        MetricKitCrashContextStore.recordLargeTimelinePayload(
            sessionId: sessionId,
            eventCount: eventCount,
            bytes: bytes,
            largestEventBytes: largestTraceEventPayloadBytes
        )
        logger.warning(
            "Cache skipped oversized trace for \(sessionId, privacy: .public) (\(eventCount) events, \(bytes) bytes)"
        )
    }

    private var largestTraceEventPayloadBytes = 0

    private func estimatedTracePayloadBytes(_ events: [TraceEvent]) -> Int {
        var total = 0
        var largest = 0
        for event in events {
            let bytes = estimatedTraceEventPayloadBytes(event)
            total += bytes
            largest = max(largest, bytes)
        }
        largestTraceEventPayloadBytes = largest
        return total
    }

    private func estimatedTraceEventPayloadBytes(_ event: TraceEvent) -> Int {
        var total = event.id.utf8.count + event.timestamp.utf8.count + event.type.rawValue.utf8.count
        total += event.text?.utf8.count ?? 0
        total += event.tool?.utf8.count ?? 0
        total += event.output?.utf8.count ?? 0
        total += event.toolCallId?.utf8.count ?? 0
        total += event.toolName?.utf8.count ?? 0
        total += event.thinking?.utf8.count ?? 0
        if let args = event.args {
            total += estimatedPayloadBytes(.object(args))
        }
        if let details = event.details {
            total += estimatedPayloadBytes(details)
        }
        if let presentation = event.presentation {
            total += presentation.kind.utf8.count
            total += presentation.title.utf8.count
            total += presentation.subtitle?.utf8.count ?? 0
            total += presentation.status?.utf8.count ?? 0
            total += presentation.body?.utf8.count ?? 0
            total += presentation.accent?.utf8.count ?? 0
            total += presentation.fields?.reduce(0) { partial, field in
                partial + field.label.utf8.count + field.value.utf8.count
            } ?? 0
        }
        return total
    }

    private func estimatedPayloadBytes(_ value: JSONValue) -> Int {
        switch value {
        case .string(let string):
            return string.utf8.count
        case .number:
            return MemoryLayout<Double>.size
        case .bool:
            return 1
        case .null:
            return 0
        case .array(let values):
            return values.reduce(0) { $0 + estimatedPayloadBytes($1) }
        case .object(let object):
            return object.reduce(0) { partial, entry in
                partial + entry.key.utf8.count + estimatedPayloadBytes(entry.value)
            }
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
