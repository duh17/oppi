import UIKit

/// What a screen shows instead of its content while that content is not
/// there: connecting, loading, empty, no search results, or failed. Every
/// whole-screen state is `UIContentUnavailableConfiguration.loadState(...)`, so
/// the words, the theme colors, and the one Retry button are the same on every
/// screen.
enum LoadState {
    /// "Connecting…": the screen's server is not connected yet.
    case connecting
    /// A spinner with its caption. A nil caption shows the spinner alone.
    case loading(String?)
    case empty(title: String, systemImage: String, message: String? = nil)
    /// A search that matched nothing.
    case noResults(query: String)
    /// A failure. With `retry` the screen offers one "Retry" button; a screen
    /// with no way to reload passes nil and shows no button.
    case failed(title: String, message: String?, retry: RetryAction?)
}

extension LoadState {
    /// A screen pinned to a paired server that has been removed.
    static var serverUnavailable: LoadState {
        .empty(
            title: String(localized: "Server Unavailable"),
            systemImage: "server.rack",
            message: String(localized: "This paired server is no longer available.")
        )
    }

    /// The same words as one line of text, for a list that shows its state in a
    /// row instead of over the whole screen: a catalog that is loading, has
    /// nothing, or matched nothing. A failure is drawn with its reason on a line
    /// of its own (`SettingsStateRowCell`); this is the one-line form, which a
    /// row's inputs are keyed by.
    var rowText: String {
        switch self {
        case .connecting:
            String(localized: "Connecting…")
        case .loading(let caption):
            caption ?? ""
        case .empty(let title, _, let message):
            [title, message].compactMap { $0 }.joined(separator: " ")
        case .noResults(let query):
            String(localized: "No results for “\(query)”.")
        case .failed(let title, let message, _):
            [title, message].compactMap { $0 }.joined(separator: ". ")
        }
    }

    /// The Retry a row shows under the state, for the states that have one. The
    /// row's button runs it on the main thread; `rowAction` says so.
    var rowRetry: (() -> Void)? {
        guard case .failed(_, _, let retry) = self else { return nil }
        return retry?.rowAction
    }
}

/// What the Retry button does: one `@MainActor` closure the state's view runs
/// when the person presses it.
struct RetryAction {
    let run: @MainActor () -> Void

    init(run: @escaping @MainActor () -> Void) {
        self.run = run
    }

    /// The same action as a plain closure, for a tap handler that does not say
    /// what actor it runs on (a list row's button): the button runs on the main
    /// thread, so the hop is the assertion.
    var rowAction: () -> Void {
        { MainActor.assumeIsolated { self.run() } }
    }
}

extension UIContentUnavailableConfiguration {
    /// A `LoadState` as a whole screen (or, with no `background`, as one list
    /// cell's content): the theme's text and symbol colors, the theme
    /// `background` behind it, a warning-colored symbol on a failure, and for
    /// a retry the one Retry button (prominent, titled "Retry").
    static func loadState(
        _ state: LoadState,
        palette: ThemePalette,
        background: UIColor? = nil
    ) -> Self {
        let fg = palette.ui.fg
        let comment = palette.ui.comment
        var config: UIContentUnavailableConfiguration
        switch state {
        case .connecting:
            config = loading()
            config.text = String(localized: "Connecting…")
            config.textProperties.color = comment
        case .loading(let caption):
            config = loading()
            config.text = caption
            config.textProperties.color = comment
        case .empty(let title, let systemImage, let message):
            config = empty()
            config.image = UIImage(systemName: systemImage)
            config.imageProperties.tintColor = comment
            config.text = title
            config.textProperties.color = fg
            config.secondaryText = message
        case .noResults(let query):
            config = search()
            config.imageProperties.tintColor = comment
            config.text = String(localized: "No Results")
            config.textProperties.color = fg
            config.secondaryText = String(localized: "No results for “\(query)”.")
        case .failed(let title, let message, let retry):
            config = empty()
            config.image = UIImage(systemName: "exclamationmark.triangle")
            config.imageProperties.tintColor = palette.ui.orange
            config.text = title
            config.textProperties.color = fg
            config.secondaryText = message
            if let retry {
                config.setProminentButton(String(localized: "Retry"), action: retry.run)
            }
        }
        config.secondaryTextProperties.color = comment
        if let background { config.background.backgroundColor = background }
        return config
    }

    /// The prominent button every load state uses (Retry, or a screen's one
    /// way out of its state, such as Server Metrics' Turn On).
    mutating func setProminentButton(_ title: String, action: @escaping @MainActor () -> Void) {
        var button = UIButton.Configuration.borderedProminent()
        button.title = title
        self.button = button
        buttonProperties.primaryAction = UIAction { _ in action() }
    }
}

extension UIContentUnavailableView {
    /// A view that shows `state` (see `UIContentUnavailableConfiguration.loadState`),
    /// for a state that fills a region of a screen. Assign `configuration` to
    /// change it.
    convenience init(
        loadState state: LoadState,
        palette: ThemePalette = ThemeRuntimeState.currentPalette(),
        background: UIColor? = nil
    ) {
        self.init(configuration: .loadState(state, palette: palette, background: background))
    }
}
