import Foundation
import Observation
import OSLog

private let composerDraftLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.chenda.Oppi",
    category: "ComposerDraft"
)

private struct ComposerDraftDocument: Codable, Sendable {
    static let currentVersion = 1

    let version: Int
    let records: [ComposerDraftRecord]
}

private struct ComposerDraftClearTombstone: Codable, Equatable, Sendable {
    let key: ComposerDraftKey
    let clearedRevision: UInt64
    let clearedAt: Date
}

private struct ComposerDraftFallbackDocument: Codable, Sendable {
    static let currentVersion = 1

    var version = currentVersion
    var activeRecord: ComposerDraftRecord?
    var additionalActiveRecords: [ComposerDraftRecord]?
    var clearTombstones: [ComposerDraftClearTombstone]

    static let empty = Self(
        activeRecord: nil,
        additionalActiveRecords: nil,
        clearTombstones: []
    )

    var activeRecords: [ComposerDraftRecord] {
        get {
            guard let activeRecord else { return additionalActiveRecords ?? [] }
            return [activeRecord] + (additionalActiveRecords ?? [])
        }
        set {
            activeRecord = newValue.first
            let remaining = Array(newValue.dropFirst())
            additionalActiveRecords = remaining.isEmpty ? nil : remaining
        }
    }

    var isEmpty: Bool {
        activeRecords.isEmpty && clearTombstones.isEmpty
    }
}

private enum ComposerDraftPersistenceError: LocalizedError {
    case unsupportedVersion(Int)
    case invalidAttachmentSidecarPath
    case missingAttachmentData

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            return "Unsupported composer draft schema version: \(version)"
        case .invalidAttachmentSidecarPath:
            return "Invalid composer draft attachment sidecar path."
        case .missingAttachmentData:
            return "Missing composer draft attachment sidecar data."
        }
    }
}

private let composerDraftSidecarDirectoryName = "draft-attachments"
private let composerDraftSidecarIOQueue = DispatchQueue(
    label: "dev.chenda.Oppi.composer-draft-sidecars",
    qos: .utility
)

private func composerDraftSidecarDirectoryURL(for fileURL: URL) -> URL {
    fileURL.deletingLastPathComponent()
        .appending(path: composerDraftSidecarDirectoryName, directoryHint: .isDirectory)
}

private func composerDraftSidecarURL(fileURL: URL, relativePath: String) -> URL? {
    guard relativePath.hasPrefix("\(composerDraftSidecarDirectoryName)/"),
          !relativePath.contains("..") else {
        return nil
    }
    return fileURL.deletingLastPathComponent()
        .appending(path: relativePath, directoryHint: .notDirectory)
}

private func configureComposerDraftStorageURL(_ url: URL) throws {
    var mutableURL = url
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try mutableURL.setResourceValues(values)

    #if os(iOS)
    try FileManager.default.setAttributes(
        [FileAttributeKey.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
        ofItemAtPath: url.path
    )
    #endif
}

/// Configure a temporary file before replacing the destination so a metadata
/// failure cannot destroy the last valid protected document.
private func writeProtectedComposerDraftData(_ data: Data, to destinationURL: URL) throws {
    let fileManager = FileManager.default
    let directoryURL = destinationURL.deletingLastPathComponent()
    try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    try configureComposerDraftStorageURL(directoryURL)

    let temporaryURL = directoryURL.appending(
        path: ".\(destinationURL.lastPathComponent).\(UUID().uuidString).tmp",
        directoryHint: .notDirectory
    )
    defer { try? fileManager.removeItem(at: temporaryURL) }

    try data.write(to: temporaryURL, options: .atomic)
    try configureComposerDraftStorageURL(temporaryURL)

    if fileManager.fileExists(atPath: destinationURL.path) {
        _ = try fileManager.replaceItemAt(
            destinationURL,
            withItemAt: temporaryURL,
            backupItemName: nil,
            options: []
        )
    } else {
        try fileManager.moveItem(at: temporaryURL, to: destinationURL)
    }
}

private func writeAttachmentSidecars(
    oldPayload: ComposerDraftPayload?,
    newPayload: ComposerDraftPayload,
    blobs: [String: Data],
    fileURL: URL
) throws {
    let oldPaths = Set(oldPayload?.attachments.compactMap(\.relativePath) ?? [])
    let newPaths = Set(newPayload.attachments.compactMap(\.relativePath))
    let fileManager = FileManager.default

    for attachment in newPayload.attachments where attachment.source == .image || attachment.source == .localFile {
        guard let relativePath = attachment.relativePath,
              let url = composerDraftSidecarURL(fileURL: fileURL, relativePath: relativePath) else {
            throw ComposerDraftPersistenceError.invalidAttachmentSidecarPath
        }
        if oldPayload?.attachments.first(where: { $0.id == attachment.id })?.relativePath == relativePath,
           fileManager.fileExists(atPath: url.path) {
            continue
        }
        guard let data = blobs[attachment.id] else {
            throw ComposerDraftPersistenceError.missingAttachmentData
        }
        try writeProtectedComposerDraftData(data, to: url)
    }

    for relativePath in oldPaths.subtracting(newPaths) {
        if let url = composerDraftSidecarURL(fileURL: fileURL, relativePath: relativePath) {
            try? fileManager.removeItem(at: url)
        }
    }

    let sidecarDirectory = composerDraftSidecarDirectoryURL(for: fileURL)
    if newPayload.attachments.contains(where: { $0.relativePath != nil && ($0.source == .image || $0.source == .localFile) }) {
        try fileManager.createDirectory(at: sidecarDirectory, withIntermediateDirectories: true)
        try configureComposerDraftStorageURL(sidecarDirectory)
    }
}

private func deleteAttachmentSidecars(for payload: ComposerDraftPayload, fileURL: URL) {
    let fileManager = FileManager.default
    for relativePath in payload.attachments.compactMap(\.relativePath) {
        if let url = composerDraftSidecarURL(fileURL: fileURL, relativePath: relativePath) {
            try? fileManager.removeItem(at: url)
        }
    }
    let directory = composerDraftSidecarDirectoryURL(for: fileURL)
    guard fileManager.fileExists(atPath: directory.path) else { return }
    let hasFiles = (try? fileManager.contentsOfDirectory(atPath: directory.path).isEmpty == false) ?? false
    if !hasFiles {
        try? fileManager.removeItem(at: directory)
    }
}

private func composerDraftRecordIsNewer(
    _ candidate: ComposerDraftRecord,
    than current: ComposerDraftRecord
) -> Bool {
    if candidate.revision != current.revision {
        return candidate.revision > current.revision
    }
    return candidate.updatedAt > current.updatedAt
}

private actor ComposerDraftPersistence {
    private let fileURL: URL
    private let lifecycleFallbackURL: URL

    init(fileURL: URL, lifecycleFallbackURL: URL) {
        self.fileURL = fileURL
        self.lifecycleFallbackURL = lifecycleFallbackURL
    }

    func load() throws -> [ComposerDraftRecord] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }

        let data = try Data(contentsOf: fileURL)
        let document = try JSONDecoder().decode(ComposerDraftDocument.self, from: data)
        guard document.version == ComposerDraftDocument.currentVersion else {
            throw ComposerDraftPersistenceError.unsupportedVersion(document.version)
        }
        return document.records
    }

    func loadAttachmentSidecars(
        for records: [ComposerDraftRecord],
        fileURL: URL
    ) -> [ComposerDraftKey: [String: Data]] {
        var result: [ComposerDraftKey: [String: Data]] = [:]
        for record in records {
            var blobs: [String: Data] = [:]
            for attachment in record.payload.attachments where attachment.source == .image || attachment.source == .localFile {
                guard let relativePath = attachment.relativePath,
                      let url = composerDraftSidecarURL(fileURL: fileURL, relativePath: relativePath),
                      let data = try? Data(contentsOf: url) else {
                    continue
                }
                blobs[attachment.id] = data
            }
            if !blobs.isEmpty {
                result[record.key] = blobs
            }
        }
        return result
    }

    func loadLifecycleFallback() throws -> ComposerDraftFallbackDocument? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: lifecycleFallbackURL.path) else { return nil }

        let data = try Data(contentsOf: lifecycleFallbackURL)
        let document = try JSONDecoder().decode(ComposerDraftFallbackDocument.self, from: data)
        guard document.version == ComposerDraftFallbackDocument.currentVersion else {
            throw ComposerDraftPersistenceError.unsupportedVersion(document.version)
        }
        return document
    }

    func save(_ records: [ComposerDraftRecord]) throws {
        let fileManager = FileManager.default
        guard !records.isEmpty else {
            if fileManager.fileExists(atPath: fileURL.path) {
                try fileManager.removeItem(at: fileURL)
            }
            return
        }

        let document = ComposerDraftDocument(
            version: ComposerDraftDocument.currentVersion,
            records: records
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(document)
        try writeProtectedComposerDraftData(data, to: fileURL)
    }
}

@MainActor @Observable
final class ComposerDraftStore {
    private struct PendingLegacyDraft {
        let serverID: String
        let sessionID: String
        let text: String
    }

    private(set) var isLoaded = false
    private(set) var lastError: String?

    @ObservationIgnored private var records: [ComposerDraftKey: ComposerDraftRecord] = [:]
    @ObservationIgnored private var latestRevisionByKey: [ComposerDraftKey: UInt64] = [:]
    @ObservationIgnored private let persistence: ComposerDraftPersistence
    @ObservationIgnored private let persistenceFileURL: URL
    @ObservationIgnored private let lifecycleFallbackURL: URL
    @ObservationIgnored private let saveDelay: Duration
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var pendingLegacyDraft: PendingLegacyDraft?
    @ObservationIgnored private var fallbackDocument = ComposerDraftFallbackDocument.empty
    @ObservationIgnored private var attachmentDataByKey: [ComposerDraftKey: [String: Data]] = [:]

    private static let quickSessionDraftKey = ComposerDraftKey(
        serverID: "__oppi_local__",
        workspaceID: "__quick_session__",
        sessionID: "__composer__"
    )

    init(
        fileURL: URL? = nil,
        fileManager: FileManager = .default,
        saveDelay: Duration = .milliseconds(250)
    ) {
        let resolvedFileURL = fileURL ?? Self.defaultFileURL(fileManager: fileManager)
        let fallbackURL = resolvedFileURL.deletingLastPathComponent()
            .appending(path: "active-draft-fallback-v2.json", directoryHint: .notDirectory)
        persistence = ComposerDraftPersistence(
            fileURL: resolvedFileURL,
            lifecycleFallbackURL: fallbackURL
        )
        persistenceFileURL = resolvedFileURL
        lifecycleFallbackURL = fallbackURL
        self.saveDelay = saveDelay
    }

    func load() async {
        guard !isLoaded else { return }

        do {
            let loadedRecords = try await persistence.load()
            for record in loadedRecords {
                mergeLoadedRecord(record)
            }
            mergeLoadedAttachmentSidecars(
                await persistence.loadAttachmentSidecars(
                    for: loadedRecords,
                    fileURL: persistenceFileURL
                )
            )
        } catch {
            lastError = "Failed to load local message drafts."
            composerDraftLogger.error("Draft load failed: \(error.localizedDescription, privacy: .public)")
        }

        do {
            if let fallback = try await persistence.loadLifecycleFallback() {
                fallbackDocument = fallback
                applyLoadedFallback(fallback)
                mergeLoadedAttachmentSidecars(
                    await persistence.loadAttachmentSidecars(
                        for: Array(records.values),
                        fileURL: persistenceFileURL
                    )
                )
            }
        } catch {
            lastError = "Failed to load the latest message draft fallback."
            composerDraftLogger.error("Draft fallback load failed: \(error.localizedDescription, privacy: .public)")
        }

        isLoaded = true
        if !fallbackDocument.isEmpty {
            scheduleSave()
        }
    }

    func record(for key: ComposerDraftKey) -> ComposerDraftRecord? {
        records[key]
    }

    private func mergeLoadedAttachmentSidecars(_ loaded: [ComposerDraftKey: [String: Data]]) {
        for (key, blobs) in loaded {
            attachmentDataByKey[key] = blobs
        }
    }

    var quickSessionDraftText: String {
        quickSessionDraftPayload.text
    }

    var quickSessionDraftPayload: ComposerDraftPayload {
        guard let key = Self.quickSessionDraftKey else { return .empty }
        return records[key]?.payload ?? .empty
    }

    func quickSessionDraftAttachmentData() -> [String: Data] {
        guard let key = Self.quickSessionDraftKey else { return [:] }
        return attachmentDataByKey[key] ?? [:]
    }

    @discardableResult
    func setQuickSessionDraftText(_ text: String) -> ComposerDraftRecord? {
        guard let key = Self.quickSessionDraftKey else { return nil }
        var payload = quickSessionDraftPayload
        payload.text = text
        return setDraft(
            payload,
            attachmentData: quickSessionDraftAttachmentData(),
            for: key
        )
    }

    @discardableResult
    func setQuickSessionDraft(
        _ payload: ComposerDraftPayload,
        attachmentData: [String: Data] = [:]
    ) -> ComposerDraftRecord? {
        guard let key = Self.quickSessionDraftKey else { return nil }
        return setDraft(payload, attachmentData: attachmentData, for: key)
    }

    func saveQuickSessionLifecycleFallback() {
        guard let key = Self.quickSessionDraftKey else { return }
        saveLifecycleFallback(records[key])
    }

    @discardableResult
    func clearQuickSessionDraft(ifRevision revision: UInt64?) -> Bool {
        guard let key = Self.quickSessionDraftKey, let revision else { return false }
        return clearDraft(for: key, ifRevision: revision)
    }

    @discardableResult
    func setDraft(
        _ payload: ComposerDraftPayload,
        attachmentData: [String: Data] = [:],
        for key: ComposerDraftKey
    ) -> ComposerDraftRecord? {
        guard !payload.isEmpty else {
            clearDraft(for: key)
            return nil
        }

        let oldPayload = records[key]?.payload
        var normalizedPayload = payload
        for index in normalizedPayload.attachments.indices {
            guard normalizedPayload.attachments[index].source == .image
                    || normalizedPayload.attachments[index].source == .localFile else {
                continue
            }
            if normalizedPayload.attachments[index].relativePath == nil {
                normalizedPayload.attachments[index].relativePath = oldPayload?.attachments.first {
                    $0.id == normalizedPayload.attachments[index].id
                }?.relativePath ?? "\(composerDraftSidecarDirectoryName)/\(UUID().uuidString).blob"
            }
        }

        var blobs = attachmentDataByKey[key] ?? [:]
        for attachment in normalizedPayload.attachments {
            if let data = attachmentData[attachment.id] {
                blobs[attachment.id] = data
            }
        }
        let retainedIDs = Set(normalizedPayload.attachments.map(\.id))
        blobs = blobs.filter { retainedIDs.contains($0.key) }
        do {
            // Keep the synchronous revision/rollback contract while moving file I/O
            // off the main actor. Debounced JSON persistence remains actor-owned.
            try composerDraftSidecarIOQueue.sync {
                try writeAttachmentSidecars(
                    oldPayload: oldPayload,
                    newPayload: normalizedPayload,
                    blobs: blobs,
                    fileURL: persistenceFileURL
                )
            }
        } catch {
            lastError = "Failed to save local message draft attachments."
            composerDraftLogger.error("Draft attachment write failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        let revision = (latestRevisionByKey[key] ?? records[key]?.revision ?? 0) &+ 1
        let record = ComposerDraftRecord(
            key: key,
            payload: normalizedPayload,
            revision: revision,
            updatedAt: Date()
        )
        latestRevisionByKey[key] = revision
        records[key] = record
        attachmentDataByKey[key] = blobs
        scheduleSave()
        return record
    }

    func attachmentData(for key: ComposerDraftKey, attachmentID: String) -> Data? {
        attachmentDataByKey[key]?[attachmentID]
    }

    @discardableResult
    func clearDraft(for key: ComposerDraftKey, ifRevision revision: UInt64? = nil) -> Bool {
        guard let current = records[key] else { return false }
        if let revision, current.revision != revision {
            return false
        }

        records.removeValue(forKey: key)
        attachmentDataByKey.removeValue(forKey: key)
        composerDraftSidecarIOQueue.sync {
            deleteAttachmentSidecars(for: current.payload, fileURL: persistenceFileURL)
        }
        latestRevisionByKey[key] = max(latestRevisionByKey[key] ?? 0, current.revision)
        recordClearTombstone(for: current)
        scheduleSave()
        return true
    }

    @discardableResult
    func clearDraft(serverID: String, workspaceID: String, sessionID: String) -> Bool {
        guard let key = ComposerDraftKey(
            serverID: serverID,
            workspaceID: workspaceID,
            sessionID: sessionID
        ) else { return false }
        return clearDraft(for: key)
    }

    /// Synchronously snapshots the active draft before iOS can suspend the process.
    /// The fallback is a separate protected, backup-excluded file so it cannot race
    /// the debounced main document write. Pending clear tombstones are preserved.
    func saveLifecycleFallback(_ record: ComposerDraftRecord?) {
        guard let record, !record.payload.isEmpty else { return }
        do {
            try composerDraftSidecarIOQueue.sync {
                try writeAttachmentSidecars(
                    oldPayload: nil,
                    newPayload: record.payload,
                    blobs: attachmentDataByKey[record.key] ?? [:],
                    fileURL: persistenceFileURL
                )
            }
        } catch {
            lastError = "Failed to save the latest message draft attachments before suspension."
            composerDraftLogger.error("Draft lifecycle attachment write failed: \(error.localizedDescription, privacy: .public)")
        }
        latestRevisionByKey[record.key] = max(latestRevisionByKey[record.key] ?? 0, record.revision)
        var activeRecords = fallbackDocument.activeRecords
        activeRecords.removeAll { $0.key == record.key }
        activeRecords.append(record)
        fallbackDocument.activeRecords = activeRecords
        fallbackDocument.clearTombstones.removeAll {
            $0.key == record.key && $0.clearedRevision < record.revision
        }
        persistFallbackDocumentReportingErrors(
            failureMessage: "Failed to save the latest message draft before suspension."
        )
    }

    func recoverDraft(_ record: ComposerDraftRecord?) {
        guard let record, !record.payload.isEmpty else { return }
        mergeLoadedRecord(record)
        scheduleSave()
    }

    func stageLegacyDraft(text: String?, serverID: String?, sessionID: String?) {
        guard let text, !text.isEmpty,
              let serverID, !serverID.isEmpty,
              let sessionID, !sessionID.isEmpty else {
            return
        }
        pendingLegacyDraft = PendingLegacyDraft(
            serverID: serverID,
            sessionID: sessionID,
            text: text
        )
    }

    func consumeLegacyDraft(for key: ComposerDraftKey) -> ComposerDraftPayload? {
        guard let pendingLegacyDraft,
              pendingLegacyDraft.serverID == key.serverID,
              pendingLegacyDraft.sessionID == key.sessionID else {
            return nil
        }

        self.pendingLegacyDraft = nil
        guard records[key] == nil else { return nil }
        return ComposerDraftPayload(text: pendingLegacyDraft.text, repoPointers: [])
    }

    func flush() async {
        saveTask?.cancel()
        saveTask = nil
        await persistCurrentRecords()
    }

    private func mergeLoadedRecord(_ record: ComposerDraftRecord) {
        guard !record.payload.isEmpty else { return }
        latestRevisionByKey[record.key] = max(latestRevisionByKey[record.key] ?? 0, record.revision)
        if let current = records[record.key],
           !composerDraftRecordIsNewer(record, than: current) {
            return
        }
        records[record.key] = record
    }

    private func applyLoadedFallback(_ fallback: ComposerDraftFallbackDocument) {
        for activeRecord in fallback.activeRecords {
            mergeLoadedRecord(activeRecord)
        }
        for tombstone in fallback.clearTombstones {
            latestRevisionByKey[tombstone.key] = max(
                latestRevisionByKey[tombstone.key] ?? 0,
                tombstone.clearedRevision
            )
            if let current = records[tombstone.key],
               current.revision <= tombstone.clearedRevision {
                records.removeValue(forKey: tombstone.key)
            }
        }
    }

    private func recordClearTombstone(for record: ComposerDraftRecord) {
        var activeRecords = fallbackDocument.activeRecords
        activeRecords.removeAll { $0.key == record.key }
        fallbackDocument.activeRecords = activeRecords
        fallbackDocument.clearTombstones.removeAll { $0.key == record.key }
        fallbackDocument.clearTombstones.append(
            ComposerDraftClearTombstone(
                key: record.key,
                clearedRevision: record.revision,
                clearedAt: Date()
            )
        )
        persistFallbackDocumentReportingErrors(
            failureMessage: "Failed to save a cleared message draft marker."
        )
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let delay = saveDelay
        saveTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.persistCurrentRecords()
        }
    }

    private func persistCurrentRecords() async {
        let snapshot = records.values.sorted { lhs, rhs in
            if lhs.key.serverID != rhs.key.serverID {
                return lhs.key.serverID < rhs.key.serverID
            }
            if lhs.key.workspaceID != rhs.key.workspaceID {
                return lhs.key.workspaceID < rhs.key.workspaceID
            }
            return lhs.key.sessionID < rhs.key.sessionID
        }

        do {
            try await persistence.save(snapshot)
            pruneFallbackDocumentCovered(by: snapshot)
            try persistFallbackDocument()
            lastError = nil
        } catch {
            lastError = "Failed to save local message drafts."
            composerDraftLogger.error("Draft save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func pruneFallbackDocumentCovered(by snapshot: [ComposerDraftRecord]) {
        var activeRecords = fallbackDocument.activeRecords
        activeRecords.removeAll { activeRecord in
            if let durableRecord = snapshot.first(where: { $0.key == activeRecord.key }) {
                return !composerDraftRecordIsNewer(activeRecord, than: durableRecord)
            }
            return fallbackDocument.clearTombstones.contains { $0.key == activeRecord.key }
        }
        fallbackDocument.activeRecords = activeRecords

        fallbackDocument.clearTombstones.removeAll { tombstone in
            guard let durableRecord = snapshot.first(where: { $0.key == tombstone.key }) else {
                return true
            }
            return durableRecord.revision > tombstone.clearedRevision
        }
    }

    private func persistFallbackDocumentReportingErrors(failureMessage: String) {
        do {
            try persistFallbackDocument()
        } catch {
            lastError = failureMessage
            composerDraftLogger.error("Draft fallback write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func persistFallbackDocument() throws {
        let fileManager = FileManager.default
        guard !fallbackDocument.isEmpty else {
            if fileManager.fileExists(atPath: lifecycleFallbackURL.path) {
                try fileManager.removeItem(at: lifecycleFallbackURL)
            }
            return
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(fallbackDocument)
        try writeProtectedComposerDraftData(data, to: lifecycleFallbackURL)
    }

    private static func defaultFileURL(fileManager: FileManager) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "ComposerDrafts", directoryHint: .isDirectory)
            .appending(path: "drafts-v1.json", directoryHint: .notDirectory)
    }
}
