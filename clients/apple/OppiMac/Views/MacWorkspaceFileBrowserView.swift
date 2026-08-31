import AppKit
import SwiftUI

enum MacWorkspaceFileBrowserPresentation: Equatable, Sendable {
    case card
    case column
}

struct MacWorkspaceFileBrowserView: View {
    let workspace: Workspace
    let worktreeId: String
    @Binding var openPlan: FileViewerPlan?
    var presentation: MacWorkspaceFileBrowserPresentation = .card

    @State private var currentPath = ""
    @State private var listing: DirectoryListingResponse?
    @State private var isLoading = false
    @State private var error: String?
    @State private var copiedPath: String?

    var body: some View {
        Group {
            if presentation == .column {
                browserContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .themedScrollSurface()
            } else {
                browserContent
                    .padding(12)
                    .background(
                        .thinMaterial,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(.themeComment.opacity(0.20), lineWidth: 1)
                    )
            }
        }
            .task(id: "\(workspace.id):\(worktreeId)") {
                currentPath = ""
                listing = nil
                await loadDirectory(path: "")
            }
    }

    private var browserContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("Workspace Files", systemImage: "folder")
                    .font(.headline)
                Text(currentPath.isEmpty ? "Root" : currentPath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.themeFgDim)
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
                    .foregroundStyle(.themeGreen)
                    .lineLimit(1)
            }
        }
        .padding(presentation == .column ? 12 : 0)
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
                List {
                    ForEach(response.entries) { entry in
                        entryRow(entry)
                            .listRowInsets(EdgeInsets(top: 1, leading: 4, bottom: 1, trailing: 4))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                    if response.truncated {
                        Text("Showing first \(response.entries.count) entries")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .frame(
                    minHeight: 120,
                    maxHeight: presentation == .column ? .infinity : 220
                )
            }
        }
    }

    private func entryRow(_ entry: FileEntry) -> some View {
        let path = FileViewerPlan.resolvedPath(
            entryPath: entry.path,
            name: entry.name,
            currentPath: currentPath
        )
        let isOpenFile = openPlan?.path == path && !entry.isDirectory
        return Button {
            if entry.isDirectory {
                Task { await openDirectory(directoryPath(for: entry)) }
            } else if let plan = FileViewerPlan.opening(
                entry: entry,
                workspaceID: workspace.id,
                currentPath: currentPath,
                worktreeId: worktreeId
            ) {
                openDocument(plan)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: entry.isDirectory ? "folder.fill" : "doc.text")
                    .foregroundStyle(entry.isDirectory ? .themeBlue : .themeFgDim)
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
                    .foregroundStyle(.themeFgDim)
                }
                Spacer(minLength: 8)
                if entry.isDirectory {
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.themeFgDim)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                (isOpenFile ? Color.themeBlue.opacity(0.14) : Color.themeBgHighlight.opacity(0.72)),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Copy Workspace Path") { copyPath(path) }
            if entry.isDirectory {
                Button("Open Directory") { Task { await openDirectory(directoryPath(for: entry)) } }
            } else if let plan = FileViewerPlan.opening(
                entry: entry,
                workspaceID: workspace.id,
                currentPath: currentPath,
                worktreeId: worktreeId
            ) {
                Button("Open") { openDocument(plan) }
            }
        }
    }

    private func loadDirectory(path: String) async {
        guard workspace.hostMount?.isEmpty == false else { return }
        guard let client = MacWorkspaceClient.localOwner() else {
            error = "Local server config is not initialized yet."
            return
        }

        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let response = try await client.listWorkspaceDirectory(
                workspaceId: workspace.id,
                path: path,
                worktreeId: worktreeId
            )
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

    private func openDocument(_ plan: FileViewerPlan) {
        openPlan = plan
    }

    private func directoryPath(for entry: FileEntry) -> String {
        let path = FileViewerPlan.resolvedPath(
            entryPath: entry.path,
            name: entry.name,
            currentPath: currentPath
        )
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
