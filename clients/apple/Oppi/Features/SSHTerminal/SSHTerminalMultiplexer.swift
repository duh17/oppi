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

    /// The multiplexer's name in what the person reads.
    var name: String {
        switch self {
        case .herdr: "Herdr"
        case .tmux: "tmux"
        }
    }

    /// Where a folder opens in this multiplexer.
    var placement: SSHTerminalMultiplexerPlacement {
        switch self {
        case .herdr:
            // The host's own terminal is the Herdr client, and Herdr is told
            // which workspace to show over that terminal's side channel.
            .hostTerminal
        case .tmux:
            // A terminal of its own, whose command attaches the folder's session.
            .folderTerminal
        }
    }

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

/// Where "Open Terminal here" lands, the same shape for every multiplexer.
enum SSHTerminalMultiplexerPlacement: Equatable, Sendable {
    /// Inside the host's own terminal: the one its Run on Connect command opened.
    case hostTerminal
    /// In a terminal of its own, which attaches a multiplexer session that was
    /// started in the folder and outlives the connection.
    case folderTerminal
}

/// One multiplexer's way of opening a folder inside it.
///
/// The two placements are why this is one small interface instead of a
/// per-multiplexer fork of the whole flow: "Open Terminal here" asks the kind
/// where its folder goes, and the same two calls open it there. A folder in
/// Herdr and a folder in tmux feel the same — you land in that folder inside
/// your multiplexer, and it is still there after a disconnect.
///
/// Nothing is ever typed into the program that is already running. A
/// `.hostTerminal` multiplexer is driven over the terminal's side exec channel,
/// and a `.folderTerminal` one is the command a new terminal runs. Each
/// implementation answers the requirement its `placement` names; the other has
/// the default below, which the flow never calls.
///
/// The implementations are plain value types that build command words and read
/// the host, so they carry no actor of their own: the async call hops to the
/// terminal's main-actor channel when it runs.
protocol SSHTerminalMultiplexer: Sendable {
    var placement: SSHTerminalMultiplexerPlacement { get }

    /// The command a `.folderTerminal` runs for `target`, or nil when this
    /// multiplexer opens the folder in the host's own terminal.
    func folderCommand(for target: SSHTerminalFolderTarget) -> String?

    /// Opens `target` in the multiplexer running in the host's terminal, which
    /// is already connected on `channel`. Throws with what to tell the person
    /// when the multiplexer refuses; they stay in that terminal either way.
    func openInHostTerminal(_ target: SSHTerminalFolderTarget, on channel: SSHTerminalChannel) async throws
}

extension SSHTerminalMultiplexer {
    func folderCommand(for target: SSHTerminalFolderTarget) -> String? { nil }
    func openInHostTerminal(_ target: SSHTerminalFolderTarget, on channel: SSHTerminalChannel) async throws {}
}

/// A multiplexer could not turn what the host reported into a folder.
enum SSHTerminalMultiplexerFailure: Error, Equatable, LocalizedError {
    /// The host's home folder could not be read, so a `~` folder cannot become
    /// the absolute path a multiplexer's CLI takes as an argument.
    case noHomeFolder

    var errorDescription: String? {
        switch self {
        case .noHomeFolder:
            "The host did not report its home folder, so this folder could not be resolved."
        }
    }
}
