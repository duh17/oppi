import AppKit
import Foundation
import SwiftUI

/// Markdown `![alt](source)` painted as an `NSImage`, with alt-text fallback.
struct MacMarkdownImageView: View {
    let alt: String
    let source: String?
    var workspaceID: String? = nil
    var sessionID: String? = nil
    var worktreeId: String? = nil
    var sourceDirectory: String? = nil

    @Environment(\.theme) private var theme
    @State private var image: NSImage?
    @State private var allowRemoteLoad = false

    private static let maxInlineHeight: CGFloat = 400
    private var isRemoteHTTP: Bool {
        MacMarkdownPaintDispatch.isRemoteHTTPSource(source)
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: Self.maxInlineHeight)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel(accessibilityName)
                    .accessibilityAddTraits(.isImage)
            } else if isRemoteHTTP && !allowRemoteLoad {
                Button("Load remote image") {
                    allowRemoteLoad = true
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(theme.accent.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(theme.bg.highlight, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("Load remote image")
                .accessibilityHint(fallbackText)
            } else {
                Text(fallbackText)
                    .font(.caption)
                    .foregroundStyle(theme.text.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(theme.bg.highlight, in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel(fallbackText)
            }
        }
        .task(id: loadIdentity) {
            image = await MacMarkdownImageLoader.nsImage(
                from: source,
                workspaceID: workspaceID,
                sessionID: sessionID,
                worktreeId: worktreeId,
                sourceDirectory: sourceDirectory,
                allowRemote: allowRemoteLoad
            )
        }
    }

    private var loadIdentity: String {
        "\(source ?? "")|\(workspaceID ?? "")|\(sessionID ?? "")|\(worktreeId ?? "")|\(sourceDirectory ?? "")|\(allowRemoteLoad)"
    }

    private var accessibilityName: String {
        let trimmed = alt.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Image" : trimmed
    }

    private var fallbackText: String {
        let trimmed = alt.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "[image]" : "[\(trimmed)]"
    }
}

/// Markdown `![alt](file.svg)` painted as source + WKWebView preview, not NSImage-only.
struct MacMarkdownSVGView: View {
    let alt: String
    let source: String?
    var workspaceID: String? = nil
    var sessionID: String? = nil
    var worktreeId: String? = nil
    var sourceDirectory: String? = nil

    @Environment(\.theme) private var theme
    @State private var markup: String?
    @State private var allowRemoteLoad = false

    private var isRemoteHTTP: Bool {
        MacMarkdownPaintDispatch.isRemoteHTTPSource(source)
    }

    var body: some View {
        Group {
            if let markup {
                MacMarkupSourcePreviewView(source: markup, kind: .svg)
            } else if isRemoteHTTP && !allowRemoteLoad {
                Button("Load remote image") {
                    allowRemoteLoad = true
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(theme.accent.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(theme.bg.highlight, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("Load remote image")
                .accessibilityHint(fallbackText)
            } else {
                Text(fallbackText)
                    .font(.caption)
                    .foregroundStyle(theme.text.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(theme.bg.highlight, in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel(fallbackText)
            }
        }
        .task(id: loadIdentity) {
            markup = await MacMarkdownImageLoader.markupSource(
                from: source,
                workspaceID: workspaceID,
                sessionID: sessionID,
                worktreeId: worktreeId,
                sourceDirectory: sourceDirectory,
                allowRemote: allowRemoteLoad
            )
        }
    }

    private var loadIdentity: String {
        "\(source ?? "")|\(workspaceID ?? "")|\(sessionID ?? "")|\(worktreeId ?? "")|\(sourceDirectory ?? "")|\(allowRemoteLoad)"
    }

    private var fallbackText: String {
        let trimmed = alt.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "[svg]" : "[\(trimmed)]"
    }
}

struct MacUserMessageImageStrip: View {
    let images: [ImageAttachment]
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(images.enumerated()), id: \.offset) { index, attachment in
                if let image = MacMarkdownImageLoader.nsImage(from: attachment) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxHeight: 220)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .accessibilityLabel("Attached image \(index + 1)")
                        .accessibilityAddTraits(.isImage)
                } else {
                    Text("[image]")
                        .font(.caption)
                        .foregroundStyle(theme.text.tertiary)
                }
            }
        }
    }
}

@MainActor
enum MacMarkdownImageLoader {
    static func nsImage(from attachment: ImageAttachment) -> NSImage? {
        guard let data = Data(base64Encoded: attachment.data, options: .ignoreUnknownCharacters) else {
            return nil
        }
        return NSImage(data: data)
    }

    static func nsImage(
        from source: String?,
        workspaceID: String? = nil,
        sessionID: String? = nil,
        worktreeId: String? = nil,
        sourceDirectory: String? = nil,
        allowRemote: Bool = false
    ) async -> NSImage? {
        guard let data = await data(
            from: source,
            workspaceID: workspaceID,
            sessionID: sessionID,
            worktreeId: worktreeId,
            sourceDirectory: sourceDirectory,
            allowRemote: allowRemote
        ) else {
            return nil
        }
        return NSImage(data: data)
    }

    static func markupSource(
        from source: String?,
        workspaceID: String? = nil,
        sessionID: String? = nil,
        worktreeId: String? = nil,
        sourceDirectory: String? = nil,
        allowRemote: Bool = false
    ) async -> String? {
        guard let data = await data(
            from: source,
            workspaceID: workspaceID,
            sessionID: sessionID,
            worktreeId: worktreeId,
            sourceDirectory: sourceDirectory,
            allowRemote: allowRemote
        ) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func data(
        from source: String?,
        workspaceID: String?,
        sessionID: String?,
        worktreeId: String?,
        sourceDirectory: String?,
        allowRemote: Bool
    ) async -> Data? {
        guard let source, !source.isEmpty else { return nil }
        if source.hasPrefix("data:") {
            return dataURIData(source)
        }
        // Host POSIX / local file: sources must not read the owner filesystem.
        // There is no sandbox-remapped authenticated image fetch on Mac yet.
        if let url = URL(string: source) {
            if url.isFileURL {
                return nil
            }
            if url.scheme == "https" || url.scheme == "http" {
                guard allowRemote else { return nil }
                return await remoteData(url)
            }
        }
        if source.hasPrefix("/") || source.hasPrefix("~") {
            return nil
        }
        if MacMarkdownPaintDispatch.isRelativeImageSource(source) {
            let path = MacMarkdownWorkspaceFileLoader.resolvedPath(source, sourceDirectory: sourceDirectory)
            if let workspaceID, !workspaceID.isEmpty {
                return await MacMarkdownWorkspaceFileLoader.data(
                    path: path,
                    workspaceID: workspaceID,
                    sessionID: sessionID,
                    worktreeId: worktreeId
                )
            }
            return nil
        }
        if FileManager.default.fileExists(atPath: source) {
            return try? Data(contentsOf: URL(fileURLWithPath: source))
        }
        return nil
    }

    private static func dataURIData(_ uri: String) -> Data? {
        guard let comma = uri.firstIndex(of: ",") else { return nil }
        let metadata = uri[uri.index(uri.startIndex, offsetBy: 5)..<comma].lowercased()
        let payload = String(uri[uri.index(after: comma)...])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let data: Data?
        if metadata.contains(";base64") {
            data = Data(base64Encoded: payload, options: [.ignoreUnknownCharacters])
        } else {
            data = payload.removingPercentEncoding?.data(using: .utf8)
        }
        guard let data, !data.isEmpty else { return nil }
        return data
    }

    private static func remoteData(_ url: URL) async -> Data? {
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            return data.isEmpty ? nil : data
        } catch {
            return nil
        }
    }
}

/// Owner Unix-socket fetch for workspace/session files. Never sends `sk_` over HTTPS.
enum MacMarkdownWorkspaceFileLoader {
    static func resolvedPath(_ source: String, sourceDirectory: String?) -> String {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let directory = sourceDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
              !directory.isEmpty else {
            return trimmed
        }
        return (directory as NSString).appendingPathComponent(trimmed)
    }

    static func workspaceRawRequestPath(
        workspaceID: String,
        path: String,
        worktreeId: String? = nil
    ) -> String? {
        MacUnixSocketMediaPath.workspaceRaw(
            workspaceID: workspaceID,
            filePath: path,
            worktreeId: worktreeId
        )
    }

    static func workspaceRawRequestPath(for plan: FileViewerPlan) -> String? {
        switch plan.source {
        case .workspaceFile(let workspaceID, let path):
            return workspaceRawRequestPath(
                workspaceID: workspaceID,
                path: path,
                worktreeId: plan.worktreeId
            )
        case .hostFile, .workspaceReviewDiff:
            return nil
        }
    }

    static func data(
        path: String,
        workspaceID: String,
        sessionID: String?,
        worktreeId: String? = nil
    ) async -> Data? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !workspaceID.isEmpty else { return nil }

        if let sessionID, !sessionID.isEmpty, let client = MacWorkspaceClient.localOwner() {
            if let data = try? await client.getSessionRawFileData(
                workspaceId: workspaceID,
                sessionId: sessionID,
                path: trimmed
            ), !data.isEmpty {
                return data
            }
        }

        return await workspaceRawData(
            workspaceID: workspaceID,
            path: trimmed,
            worktreeId: worktreeId
        )
    }

    static func data(for plan: FileViewerPlan, sessionID: String?) async -> Data? {
        switch plan.source {
        case .workspaceFile(let workspaceID, let path):
            return await data(
                path: path,
                workspaceID: workspaceID,
                sessionID: sessionID,
                worktreeId: plan.worktreeId
            )
        case .hostFile(let path):
            return await hostRawData(path: path)
        case .workspaceReviewDiff:
            return nil
        }
    }

    static func temporaryFileURL(
        path: String,
        workspaceID: String,
        sessionID: String?,
        worktreeId: String? = nil
    ) async -> URL? {
        guard let data = await data(
            path: path,
            workspaceID: workspaceID,
            sessionID: sessionID,
            worktreeId: worktreeId
        ), !data.isEmpty else {
            return nil
        }
        let ext = (path as NSString).pathExtension
        let fileName = UUID().uuidString + (ext.isEmpty ? "" : ".\(ext)")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    private static func hostRawData(path: String) async -> Data? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let data = await hostSocketData(path: trimmed), !data.isEmpty {
            return data
        }
        let expanded = (trimmed as NSString).expandingTildeInPath
        return try? Data(contentsOf: URL(fileURLWithPath: expanded))
    }

    private static func hostSocketData(path: String) async -> Data? {
        guard let token = MacAPIClient.readOwnerToken() else { return nil }
        let dataDir = NSString("~/.config/oppi").expandingTildeInPath
        let client = MacUnixSocketHTTPClient(socketPath: MacLocalAPISocket.path(dataDir: dataDir))
        var components = URLComponents()
        components.path = "/files/raw"
        components.queryItems = [URLQueryItem(name: "path", value: path)]
        guard let requestPath = components.string else { return nil }
        do {
            let response = try await client.perform(
                macLocalAuthenticatedRequest(method: "GET", path: requestPath, token: token)
            )
            guard (200..<300).contains(response.statusCode), !response.body.isEmpty else {
                return nil
            }
            return response.body
        } catch {
            return nil
        }
    }

    private static func workspaceRawData(
        workspaceID: String,
        path: String,
        worktreeId: String?
    ) async -> Data? {
        guard let client = MacWorkspaceClient.localOwner() else { return nil }
        guard let data = try? await client.getWorkspaceRawFileData(
            workspaceId: workspaceID,
            path: path,
            worktreeId: worktreeId
        ), !data.isEmpty else {
            return nil
        }
        return data
    }
}
