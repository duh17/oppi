import Foundation

/// Which multiplexer a saved host's Run on Connect command starts, if any.
///
/// Detection reads the first word of the saved command by its name: `herdr`,
/// `/Users/me/.local/bin/herdr`, and `herdr --attach` are Herdr; `tmux` and
/// `tmux new -A -s main` are tmux. Anything else — a login shell, another
/// program, an empty command, or a first word hidden behind a quote or an alias
/// this device cannot see — is no multiplexer, and "Open Terminal here" stays
/// the plain folder shell it has always been.
enum SSHTerminalMultiplexerKind: String, CaseIterable, Sendable {
    case herdr
    case tmux

    /// The implementation. A new multiplexer is one case here and one type
    /// conforming to `SSHTerminalMultiplexer`.
    var multiplexer: any SSHTerminalMultiplexer {
        switch self {
        case .herdr: HerdrMultiplexer()
        case .tmux: TmuxMultiplexer()
        }
    }

    /// The multiplexer `startupCommand` starts, or nil for a login shell or any
    /// other program.
    static func detected(in startupCommand: String?) -> Self? {
        guard let command = startupCommand?.trimmingCharacters(in: .whitespacesAndNewlines),
              let first = command.split(whereSeparator: \.isWhitespace).first else { return nil }
        // A path to the binary is the binary; flags after it are not part of the name.
        let name = first.split(separator: "/").last.map(String.init) ?? String(first)
        return Self(rawValue: name)
    }
}

/// Where one multiplexer puts the folder, and what has to happen for it to get
/// there. One value per opening keeps every caller identical for every
/// multiplexer: a folder in Herdr and a folder in tmux feel the same.
enum SSHTerminalMultiplexerOpening {
    /// Inside the host's own terminal, the one its Run on Connect command
    /// already runs: the handler drives the multiplexer over that terminal's side
    /// exec channel. Nothing is typed into the program.
    case inHostTerminal((SSHTerminalChannel) async throws -> Void)
    /// In a terminal of its own, running this command, which attaches the
    /// multiplexer session started in the folder.
    case folderTerminal(command: String)
}

/// One multiplexer's way of opening a folder inside it.
///
/// The folders of `.folderTerminal` multiplexers outlive a disconnect because the
/// session does; `.inHostTerminal` ones live in the session the host's terminal
/// already shows. Either way the person lands in that folder inside their
/// multiplexer, and nothing is ever typed into a running program.
///
/// The implementation is a plain value type that builds command words and reads
/// the host, so it carries no actor of its own: the async handler hops to the
/// terminal's main-actor channel when it runs.
protocol SSHTerminalMultiplexer: Sendable {
    /// The multiplexer's name, in what the person reads.
    var name: String { get }

    /// How this multiplexer opens `target`, or nil when the folder is not one the
    /// host can open (a relative path, say).
    func opening(_ target: SSHTerminalFolderTarget) -> SSHTerminalMultiplexerOpening?
}

/// A multiplexer could not turn what the host reported into a folder.
enum SSHTerminalMultiplexerFailure: Error, Equatable, LocalizedError {
    /// The host's home folder could not be read, so a `~` folder cannot become
    /// the absolute path a multiplexer's CLI takes as an argument.
    case noHomeFolder
    /// The folder is not one the host can open: neither absolute nor `~`.
    case unusableFolder

    var errorDescription: String? {
        switch self {
        case .noHomeFolder:
            "The host did not report its home folder, so this folder could not be resolved."
        case .unusableFolder:
            "This folder is not an absolute path on the host, so it cannot be opened there."
        }
    }
}
