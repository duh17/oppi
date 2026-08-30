import SwiftUI

/// Oppi `![[video]]` embed painted with `AVPlayerView`, not `displayLabel` text.
struct MacMarkdownVideoView: View {
    let embed: MarkdownVideoEmbed
    var worktreeId: String? = nil
    @Environment(\.theme) private var theme
    @State private var allowRemoteLoad = false

    private var playback: MacAVPlayback {
        Self.playback(for: embed, allowRemote: allowRemoteLoad, worktreeId: worktreeId)
    }

    private var isRemoteHTTP: Bool {
        guard let resolved = Self.hostResolvedURL(for: embed) else { return false }
        let scheme = resolved.scheme?.lowercased()
        return scheme == "http" || scheme == "https"
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            MacAuthenticatedAVPlayerView(playback: playback)
            if playback.isIdle {
                if isRemoteHTTP && !allowRemoteLoad {
                    Button("Load remote video") {
                        allowRemoteLoad = true
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(theme.accent.primary)
                    .padding(8)
                    .accessibilityLabel("Load remote video")
                } else {
                    Text(embed.displayLabel)
                        .font(.caption)
                        .foregroundStyle(theme.text.secondary)
                        .padding(8)
                        .allowsHitTesting(false)
                }
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .frame(maxHeight: 360)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .background(theme.bg.highlight, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(embed.displayLabel)
        .accessibilityIdentifier("markdown-video")
        .accessibilityAddTraits(.startsMediaSession)
    }

    nonisolated static func hostResolvedURL(for embed: MarkdownVideoEmbed) -> URL? {
        let candidates = [embed.filePath, embed.reference.target]
        for path in candidates {
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() {
                if scheme == "file" || scheme == "https" || scheme == "http" {
                    return url
                }
            }
            if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
                let expanded = (trimmed as NSString).expandingTildeInPath
                return URL(fileURLWithPath: expanded)
            }
            if FileManager.default.fileExists(atPath: trimmed) {
                return URL(fileURLWithPath: trimmed)
            }
        }
        return nil
    }

    nonisolated static func playback(
        for embed: MarkdownVideoEmbed,
        allowRemote: Bool = false,
        worktreeId: String? = nil,
        ownerToken: String? = MacAPIClient.readOwnerToken(),
        socketPath: String = MacLocalAPISocket.path(
            dataDir: NSString("~/.config/oppi").expandingTildeInPath
        )
    ) -> MacAVPlayback {
        if let url = hostResolvedURL(for: embed) {
            let scheme = url.scheme?.lowercased()
            if scheme == "http" || scheme == "https" {
                guard allowRemote, MacAVPlaybackURLPolicy.allows(url) else { return .idle }
                return .fileURL(url)
            }
            guard MacAVPlaybackURLPolicy.allows(url) else { return .idle }
            return .fileURL(url)
        }
        guard let workspaceID = embed.reference.workspaceID,
              !workspaceID.isEmpty else {
            return .idle
        }
        let path = embed.filePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~") else {
            return .idle
        }
        guard let token = ownerToken, !token.isEmpty else { return .idle }
        if let sessionID = embed.reference.sourceSessionID, !sessionID.isEmpty,
           let source = MacOwnerMediaSource.sessionFile(
            workspaceID: workspaceID,
            sessionID: sessionID,
            path: path,
            token: token,
            socketPath: socketPath
           ) {
            return .ownerSocket(source)
        }
        guard let source = MacOwnerMediaSource.workspaceFile(
            workspaceID: workspaceID,
            path: path,
            token: token,
            socketPath: socketPath,
            worktreeId: worktreeId
        ) else {
            return .idle
        }
        return .ownerSocket(source)
    }
}
