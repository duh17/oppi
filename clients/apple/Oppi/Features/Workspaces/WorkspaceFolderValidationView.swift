import SwiftUI

/// What the server said about a typed workspace folder: checking, missing with
/// a confirm-before-create flow, invalid, or valid. Shared by New Workspace and
/// Workspace Details so both validate and create folders the same way.
///
/// The caller owns the check and the create call; this view only presents them.
struct WorkspaceFolderValidationView: View {
    /// The trimmed folder path the status describes.
    let folder: String
    let status: HostPathStatus?
    let validationMessage: String?
    let isChecking: Bool
    let isCreating: Bool
    /// The path the user asked to create and has not yet confirmed.
    @Binding var pendingCreation: String?
    /// "the server" or the server's name, used in the confirmation sentence.
    let serverName: String
    /// Accessibility prefix: `workspace.edit` or `workspace.create`.
    let identifierPrefix: String
    let confirmCreate: () -> Void

    private var isMissing: Bool {
        guard let status else { return false }
        return status.path == folder && status.issue == "missing"
    }

    private var isValid: Bool {
        guard let status else { return false }
        return status.path == folder && status.isValidWorkspaceDirectory
    }

    /// Whether there is anything to show. Callers emit this view only then, so
    /// an empty body never leaves a blank row in a list section.
    var hasContent: Bool {
        !folder.isEmpty && (isChecking || isMissing || validationMessage != nil || isValid)
    }

    var body: some View {
        if !folder.isEmpty {
            if isChecking {
                Label("Checking folder\u{2026}", systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.themeComment)
            } else if isMissing {
                missingFolder
            } else if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.themeRed)
            } else if isValid {
                Label("Folder exists", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.themeGreen)
            }
        }
    }

    private var missingFolder: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Folder doesn\u{2019}t exist", systemImage: "folder.badge.plus")
                .font(.caption)
                .foregroundStyle(.themeComment)

            if pendingCreation == folder {
                Text("Create this one folder on \(serverName)? The parent folder must already exist.")
                    .font(.caption)
                    .foregroundStyle(.themeComment)

                if isCreating {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Creating folder\u{2026}")
                            .font(.caption)
                            .foregroundStyle(.themeComment)
                    }
                } else {
                    HStack(spacing: 8) {
                        Button {
                            confirmCreate()
                        } label: {
                            Label("Create Folder", systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("\(identifierPrefix).confirmCreateFolder")

                        Button("Cancel") {
                            pendingCreation = nil
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("\(identifierPrefix).cancelCreateFolder")
                    }
                    .controlSize(.small)
                }
            } else {
                Button {
                    pendingCreation = folder
                } label: {
                    Label("Create This Folder", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("\(identifierPrefix).createMissingFolder")
                .disabled(isCreating)
            }
        }
    }
}
