import UIKit

/// What the bottom bar's terminal switcher offers: every open terminal in
/// `SSHTerminalRegistry`, with the one on screen checked.
///
/// The switcher never connects. Choosing a row shows the terminal the registry
/// already holds (`SSHTerminalConnectSession.show`), the same live channel and
/// grid as tapping a Connected host in the list.
enum SSHTerminalSwitcher {
    /// The glyph a row carries: a connected terminal, or one whose program is
    /// blocked and waiting for the person.
    enum State: Equatable {
        case connected
        case blocked(SessionStatusKind)
    }

    struct Item: Equatable {
        let identity: SSHTerminalIdentity
        /// The saved host, `user@host`.
        let title: String
        /// The folder's last component for a folder terminal; for the host's
        /// own terminal its Run on Connect command, or Login shell. A blocked
        /// terminal adds what it waits on.
        let subtitle: String
        let state: State
        let isCurrent: Bool
    }

    /// Menu rows for `terminals`, in the registry's order.
    @MainActor
    static func items(terminals: [SSHTerminalRegistry.Terminal], current: SSHTerminalChannel) -> [Item] {
        terminals.map { terminal in
            let blocked = SSHTerminalProgramStatusPresentation.rollup(
                store: terminal.channel.programStatus,
                isStopped: false,
                seenAt: SSHTerminalProgramStatusPresentation.seenAt
            )?.headline.flatMap { $0.isBlocked ? $0 : nil }
            var subtitle = detail(profile: terminal.profile, folder: terminal.folder)
            if let blocked { subtitle += " \u{00B7} " + blocked.label }
            return Item(
                identity: SSHTerminalIdentity(profileID: terminal.profile.id, folder: terminal.folder),
                title: terminal.profile.endpointLabel,
                subtitle: subtitle,
                state: blocked.map(State.blocked) ?? .connected,
                isCurrent: terminal.channel === current
            )
        }
    }

    /// The remote folder as stored (`~` is the host's home): its last component.
    static func folderName(_ folder: String) -> String {
        let trimmed = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: true)
        return parts.last.map(String.init) ?? trimmed
    }

    private static func detail(profile: SSHTerminalProfile, folder: String?) -> String {
        if let folder { return folderName(folder) }
        let command = profile.startupCommand?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return command.isEmpty ? "Login shell" : command
    }

    /// One action per item. `select` gets the item's index. The accessibility
    /// identifiers are `sshTerminal.switcher.<index>`.
    @MainActor
    static func menuElements(
        items: [Item],
        themeID: ThemeID,
        select: @escaping @MainActor (Int) -> Void
    ) -> [UIMenuElement] {
        items.enumerated().map { index, item in
            let image: UIImage?
            switch item.state {
            case .connected:
                image = UIImage(systemName: "circle.fill")?
                    .withTintColor(UIColor(themeID.palette.green), renderingMode: .alwaysOriginal)
            case .blocked(let kind):
                image = UIImage(systemName: kind.terminalSymbol)?
                    .withTintColor(UIColor(kind.tint(themeID.appTheme)), renderingMode: .alwaysOriginal)
            }
            let action = UIAction(
                title: item.title,
                subtitle: item.subtitle,
                image: image,
                state: item.isCurrent ? .on : .off
            ) { _ in select(index) }
            action.accessibilityIdentifier = "sshTerminal.switcher.\(index)"
            return action
        }
    }
}
