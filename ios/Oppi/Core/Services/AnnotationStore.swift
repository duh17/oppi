import Foundation
import OSLog

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "AnnotationStore")

/// Observable store for diff annotations on a single file within a workspace.
///
/// Fetches annotations from the server API and provides lookup by line number
/// for inline rendering in `UnifiedDiffView`. Supports creating, resolving,
/// and deleting annotations.
@Observable
@MainActor
final class AnnotationStore {
    // MARK: - Published state

    private(set) var annotations: [DiffAnnotation] = []
    private(set) var isLoading = false
    private(set) var error: String?

    // MARK: - Config

    let workspaceId: String
    let path: String

    // MARK: - Init

    init(workspaceId: String, path: String) {
        self.workspaceId = workspaceId
        self.path = path
    }

    // MARK: - Derived

    var pendingCount: Int { annotations.count { $0.resolution.isPending } }
    var acceptedCount: Int { annotations.count { $0.resolution == .accepted } }
    var rejectedCount: Int { annotations.count { $0.resolution == .rejected } }
    var totalCount: Int { annotations.count }
    var allResolved: Bool { !annotations.isEmpty && pendingCount == 0 }

    /// Annotations grouped by anchor line for inline rendering.
    /// File-level annotations are grouped under line -1.
    var annotationsByLine: [Int: [DiffAnnotation]] {
        Dictionary(grouping: annotations) { $0.anchorLine ?? -1 }
    }

    /// Annotations for a specific line number.
    func annotations(forLine line: Int) -> [DiffAnnotation] {
        annotationsByLine[line] ?? []
    }

    /// File-level annotations (not anchored to a specific line).
    var fileLevelAnnotations: [DiffAnnotation] {
        annotations.filter { $0.isFileLevel }
    }

    // MARK: - Load

    func load(api: APIClient) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let response = try await api.getAnnotations(workspaceId: workspaceId, path: path)
            annotations = response.annotations
            error = nil
            logger.debug("Loaded \(response.annotations.count) annotations for \(self.path)")
        } catch {
            self.error = error.localizedDescription
            logger.error("Failed to load annotations: \(error)")
        }
    }

    // MARK: - Create

    func create(
        side: AnnotationSide,
        startLine: Int?,
        endLine: Int? = nil,
        body: String,
        severity: AnnotationSeverity? = .info,
        attachments: [AnnotationImageAttachment]? = nil,
        api: APIClient
    ) async {
        do {
            let requestBody = CreateAnnotationBody(
                path: path,
                side: side,
                startLine: startLine,
                endLine: endLine,
                body: body,
                author: .human,
                sessionId: nil,
                severity: severity,
                attachments: attachments
            )
            let created = try await api.createAnnotation(workspaceId: workspaceId, body: requestBody)
            annotations.append(created)
            logger.debug("Created annotation \(created.id) on \(self.path):\(startLine ?? -1)")
        } catch {
            self.error = error.localizedDescription
            logger.error("Failed to create annotation: \(error)")
        }
    }

    // MARK: - Resolve

    func resolve(annotationId: String, resolution: AnnotationResolution, api: APIClient) async {
        do {
            let updated = try await api.updateAnnotation(
                workspaceId: workspaceId,
                annotationId: annotationId,
                body: UpdateAnnotationBody(resolution: resolution)
            )
            if let index = annotations.firstIndex(where: { $0.id == annotationId }) {
                annotations[index] = updated
            }
            logger.debug("Resolved annotation \(annotationId) -> \(resolution.rawValue)")
        } catch {
            self.error = error.localizedDescription
            logger.error("Failed to resolve annotation: \(error)")
        }
    }

    // MARK: - Delete

    func delete(annotationId: String, api: APIClient) async {
        do {
            try await api.deleteAnnotation(workspaceId: workspaceId, annotationId: annotationId)
            annotations.removeAll { $0.id == annotationId }
            logger.debug("Deleted annotation \(annotationId)")
        } catch {
            self.error = error.localizedDescription
            logger.error("Failed to delete annotation: \(error)")
        }
    }

    // MARK: - Offline

    func setOffline() {
        error = "Server is offline"
    }
}
