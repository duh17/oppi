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
/// under `Library/Caches/`. Session traces are plaintext JSON copies of server
/// history, so this cache is sandbox-private but intentionally disposable.
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
    private let maxDiskBytes: Int64
    private let maxTraceAge: TimeInterval?
    private let now: @Sendable () -> Date

    // Telemetry (best-effort, process-local)
    private var hitCount = 0
    private var missCount = 0
    private var decodeFailureCount = 0
    private var writeCount = 0
    private var totalLoadMs = 0
    private var loadSamples = 0

    init(
        rootURL: URL? = nil,
        fileManager: FileManager = .default,
        maxDiskBytes: Int64 = 256 * 1024 * 1024,
        maxTraceAge: TimeInterval? = 30 * 24 * 60 * 60,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fileManager = fileManager

        let usesDefaultRoot = rootURL == nil
        let resolvedRoot = rootURL ?? Self.defaultRootURL(fileManager: fileManager)
        let resolvedTracesDir = resolvedRoot.appending(path: "traces", directoryHint: .isDirectory)
        let resolvedMaxDiskBytes = max(0, maxDiskBytes)
        root = resolvedRoot
        tracesDir = resolvedTracesDir
        self.maxDiskBytes = resolvedMaxDiskBytes
        self.maxTraceAge = maxTraceAge
        self.now = now

        encoder = JSONEncoder()
        decoder = JSONDecoder()

        if usesDefaultRoot {
            Self.removeApplicationSupportCacheRoot(fileManager: fileManager)
        }
        Self.prepareStorageDirectories(fileManager: fileManager, root: resolvedRoot, tracesDir: resolvedTracesDir)
        Self.pruneIfNeeded(
            fileManager: fileManager,
            root: resolvedRoot,
            tracesDir: resolvedTracesDir,
            maxDiskBytes: resolvedMaxDiskBytes,
            maxTraceAge: maxTraceAge,
            now: now()
        )

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

            let cached = CachedTrace(
                sessionId: sessionId,
                eventCount: events.count,
                lastEventId: events.last?.id,
                savedAt: Date(),
                events: events
            )
            let data = try encoder.encode(cached)

            try data.write(to: url, options: .atomic)
            applyFileProtection(to: url)
            writeCount += 1
            pruneIfNeeded()
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
        Self.diskSize(fileManager: fileManager, root: root)
    }

    // MARK: - Cleanup

    /// Clear all cached data.
    func clear() {
        try? fileManager.removeItem(at: root)
        prepareStorageDirectories()

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
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let appRoot = caches.appending(path: AppIdentifiers.subsystem, directoryHint: .isDirectory)
        return appRoot.appending(path: "timeline-cache", directoryHint: .isDirectory)
    }

    private static func applicationSupportCacheRootURL(fileManager: FileManager) -> URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let appRoot = appSupport.appending(path: AppIdentifiers.subsystem, directoryHint: .isDirectory)
        return appRoot.appending(path: "cache", directoryHint: .isDirectory)
    }

    private static func removeApplicationSupportCacheRoot(fileManager: FileManager) {
        let oldRoot = applicationSupportCacheRootURL(fileManager: fileManager)
        guard fileManager.fileExists(atPath: oldRoot.path) else { return }
        try? fileManager.removeItem(at: oldRoot)
        logger.notice("Removed previous Application Support timeline cache")
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
            applyFileProtection(to: url)
            writeCount += 1
            pruneIfNeeded()
            logger.debug("Cache saved: \(filename) (\(data.count) bytes)")
        } catch {
            logger.warning("Cache write failed for \(filename): \(error.localizedDescription)")
        }
    }

    private struct CacheFileEntry {
        let url: URL
        let size: Int64
        let modifiedAt: Date
    }

    private func prepareStorageDirectories() {
        Self.prepareStorageDirectories(fileManager: fileManager, root: root, tracesDir: tracesDir)
    }

    private static func prepareStorageDirectories(fileManager: FileManager, root: URL, tracesDir: URL) {
        try? fileManager.createDirectory(at: tracesDir, withIntermediateDirectories: true)
        excludeFromBackup(root)
        applyFileProtection(fileManager: fileManager, to: root)
        applyFileProtection(fileManager: fileManager, to: tracesDir)
    }

    private func pruneIfNeeded() {
        Self.pruneIfNeeded(
            fileManager: fileManager,
            root: root,
            tracesDir: tracesDir,
            maxDiskBytes: maxDiskBytes,
            maxTraceAge: maxTraceAge,
            now: now()
        )
    }

    private static func pruneIfNeeded(
        fileManager: FileManager,
        root: URL,
        tracesDir: URL,
        maxDiskBytes: Int64,
        maxTraceAge: TimeInterval?,
        now: Date
    ) {
        removeExpiredTraceFiles(
            fileManager: fileManager,
            tracesDir: tracesDir,
            maxTraceAge: maxTraceAge,
            now: now
        )
        enforceDiskBudget(
            fileManager: fileManager,
            root: root,
            tracesDir: tracesDir,
            maxDiskBytes: maxDiskBytes
        )
    }

    private static func removeExpiredTraceFiles(
        fileManager: FileManager,
        tracesDir: URL,
        maxTraceAge: TimeInterval?,
        now: Date
    ) {
        guard let maxTraceAge else { return }
        let cutoff = now.addingTimeInterval(-maxTraceAge)
        var removedCount = 0
        var removedBytes: Int64 = 0

        for entry in traceFileEntries(fileManager: fileManager, tracesDir: tracesDir) where entry.modifiedAt < cutoff {
            if removeTraceFile(fileManager: fileManager, entry: entry) {
                removedCount += 1
                removedBytes += entry.size
            }
        }

        if removedCount > 0 {
            logger.info("Cache pruned expired traces count=\(removedCount, privacy: .public) bytes=\(removedBytes, privacy: .public)")
        }
    }

    private static func enforceDiskBudget(
        fileManager: FileManager,
        root: URL,
        tracesDir: URL,
        maxDiskBytes: Int64
    ) {
        var total = diskSize(fileManager: fileManager, root: root)
        guard total > maxDiskBytes else { return }

        let entries = traceFileEntries(fileManager: fileManager, tracesDir: tracesDir).sorted { lhs, rhs in
            if lhs.modifiedAt != rhs.modifiedAt { return lhs.modifiedAt < rhs.modifiedAt }
            return lhs.url.lastPathComponent < rhs.url.lastPathComponent
        }

        var removedCount = 0
        var removedBytes: Int64 = 0
        for entry in entries {
            guard total > maxDiskBytes else { break }
            if removeTraceFile(fileManager: fileManager, entry: entry) {
                total = max(0, total - entry.size)
                removedCount += 1
                removedBytes += entry.size
            }
        }

        if removedCount > 0 {
            logger.info("Cache pruned traces for budget count=\(removedCount, privacy: .public) bytes=\(removedBytes, privacy: .public) budget=\(maxDiskBytes, privacy: .public)")
        }
    }

    private static func diskSize(fileManager: FileManager, root: URL) -> Int64 {
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

    private static func traceFileEntries(fileManager: FileManager, tracesDir: URL) -> [CacheFileEntry] {
        guard let enumerator = fileManager.enumerator(
            at: tracesDir,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var entries: [CacheFileEntry] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .contentModificationDateKey]),
                  values.isRegularFile == true,
                  let size = values.fileSize
            else { continue }
            entries.append(CacheFileEntry(
                url: url,
                size: Int64(size),
                modifiedAt: values.contentModificationDate ?? .distantPast
            ))
        }
        return entries
    }

    private static func removeTraceFile(fileManager: FileManager, entry: CacheFileEntry) -> Bool {
        do {
            try fileManager.removeItem(at: entry.url)
            return true
        } catch {
            logger.warning("Cache prune failed for \(entry.url.lastPathComponent, privacy: .public): \(error.localizedDescription)")
            return false
        }
    }

    private static func excludeFromBackup(_ url: URL) {
        var mutableURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutableURL.setResourceValues(values)
    }

    private func applyFileProtection(to url: URL) {
        Self.applyFileProtection(fileManager: fileManager, to: url)
    }

    private static func applyFileProtection(fileManager: FileManager, to url: URL) {
        #if os(iOS)
        try? fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        #endif
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
