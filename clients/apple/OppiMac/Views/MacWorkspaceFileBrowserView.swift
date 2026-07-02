import AppKit
import SwiftUI

struct MacWorkspaceFileBrowserView: View {
    let workspace: Workspace

    @State private var currentPath = ""
    @State private var listing: DirectoryListingResponse?
    @State private var isLoading = false
    @State private var error: String?
    @State private var copiedPath: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("Workspace files", systemImage: "folder")
                    .font(.headline)
                Text(currentPath.isEmpty ? "Root" : currentPath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if !currentPath.isEmpty {
                    Button {
                        Task { await openDirectory(parentPath(for: currentPath)) }
                    } label: {
                        Label("Back", systemImage: "chevron.up")
                    }
                    .controlSize(.small)
                }
                Button {
                    Task { await loadDirectory(path: currentPath) }
                } label: {
                    Label("Refresh Files", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
                .disabled(isLoading)
            }

            if workspace.hostMount?.isEmpty != false {
                ContentUnavailableView(
                    "No local folder",
                    systemImage: "folder.badge.questionmark",
                    description: Text("Set a local folder path before browsing workspace files.")
                )
                .frame(maxWidth: .infinity, minHeight: 120)
            } else if isLoading, listing == nil {
                ProgressView("Loading files...")
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else if let error, listing == nil {
                ContentUnavailableView(
                    "Could not load files",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
                .frame(maxWidth: .infinity, minHeight: 120)
            } else if let listing {
                fileList(listing)
            }

            if let copiedPath {
                Label("Copied \(copiedPath)", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
        .task(id: workspace.id) {
            currentPath = ""
            listing = nil
            await loadDirectory(path: "")
        }
    }

    private func fileList(_ response: DirectoryListingResponse) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if response.entries.isEmpty {
                ContentUnavailableView(
                    "Empty directory",
                    systemImage: "folder",
                    description: Text("No files in this directory.")
                )
                .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(response.entries) { entry in
                            entryRow(entry)
                        }
                        if response.truncated {
                            Text("Showing first \(response.entries.count) entries")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.top, 4)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(minHeight: 120, maxHeight: 220)
            }
        }
    }

    private func entryRow(_ entry: FileEntry) -> some View {
        let path = entryPath(for: entry)
        return HStack(spacing: 8) {
            Image(systemName: entry.isDirectory ? "folder.fill" : "doc.text")
                .foregroundStyle(entry.isDirectory ? Color.accentColor : Color.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 8) {
                    if !entry.formattedSize.isEmpty {
                        Text(entry.formattedSize)
                    }
                    Text(entry.relativeModifiedTime)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if entry.isDirectory {
                Button {
                    Task { await openDirectory(directoryPath(for: entry)) }
                } label: {
                    Label("Open", systemImage: "chevron.right")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
            } else {
                Button {
                    copyPath(path)
                } label: {
                    Label("Copy Path", systemImage: "doc.on.doc")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contextMenu {
            Button("Copy Workspace Path") { copyPath(path) }
            if entry.isDirectory {
                Button("Open Directory") { Task { await openDirectory(directoryPath(for: entry)) } }
            }
        }
    }

    private func loadDirectory(path: String) async {
        guard workspace.hostMount?.isEmpty == false else { return }
        guard let token = MacAPIClient.readOwnerToken(dataDir: ServerProcessManager.serverDataDir),
              let baseURL = MacServerLifecycle.defaultBaseURL else {
            error = "Local server config is not initialized yet."
            return
        }

        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let client = MacWorkspaceClient(baseURL: baseURL, token: token)
            let response = try await client.listWorkspaceDirectory(workspaceId: workspace.id, path: path)
            guard currentPath == path, !Task.isCancelled else { return }
            listing = response
        } catch {
            guard currentPath == path, !Task.isCancelled else { return }
            self.error = error.localizedDescription
            listing = nil
        }
    }

    private func openDirectory(_ path: String) async {
        currentPath = path
        listing = nil
        await loadDirectory(path: path)
    }

    private func entryPath(for entry: FileEntry) -> String {
        if let path = entry.path { return path }
        if currentPath.isEmpty { return entry.name }
        return currentPath.hasSuffix("/") ? "\(currentPath)\(entry.name)" : "\(currentPath)/\(entry.name)"
    }

    private func directoryPath(for entry: FileEntry) -> String {
        let path = entryPath(for: entry)
        return path.hasSuffix("/") ? path : "\(path)/"
    }

    private func parentPath(for path: String) -> String {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let slash = trimmed.lastIndex(of: "/") else { return "" }
        return String(trimmed[..<slash]) + "/"
    }

    private func copyPath(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
        copiedPath = path
    }
}
