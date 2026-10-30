import UIKit

/// The dialog for an extension UI method the app has no native screen for: the
/// request's message, "Unsupported extension UI" with the method it asked
/// for, and how long the request stays open. Cancel answers the request as
/// cancelled and closes the dialog once the server has it; the dialog cannot
/// be swiped away while it waits for that answer.
///
/// `AppRootModals` presents it for `ServerConnection.activeExtensionDialog`.
@MainActor
final class ExtensionDialogFallbackViewController: ListScreenController<
    ExtensionDialogFallbackViewController.Section,
    ExtensionDialogFallbackViewController.Item
> {
    enum Section: Hashable, Sendable { case message, unsupported, timeout }
    enum Item: Hashable, Sendable { case message, unsupported, timeout }

    private(set) var request: ExtensionUIRequest
    private let connection: ServerConnection
    private var isSubmitting = false
    /// A response that lands after the server already closed the dialog must
    /// not finish a closed sheet.
    private var isVisible = false
    private lazy var cancelItem: UIBarButtonItem = {
        let item = UIBarButtonItem(
            title: String(localized: "Cancel"),
            primaryAction: UIAction { [weak self] _ in self?.cancelRequest() }
        )
        item.accessibilityIdentifier = "extension.dialog.cancel"
        return item
    }()

    init(request: ExtensionUIRequest, connection: ServerConnection, root: AppRootEnvironment) {
        self.request = request
        self.connection = connection
        super.init(
            title: Self.title(of: request),
            listIdentifier: "extension.dialog.list",
            scope: .device
        )
        traitOverrides.appRootEnvironment = root
        navigationItem.leftBarButtonItem = cancelItem
        isModalInPresentation = true
    }

    /// The same request, replaced by the server with new content (a queued
    /// request that came back under its id): title, message, and timeout redraw.
    func update(request next: ExtensionUIRequest) {
        guard next.id == request.id, next != request else { return }
        request = next
        title = Self.title(of: next)
        setNeedsUpdateProperties()
    }

    /// The request's title, or "Extension" when it has none.
    static func title(of request: ExtensionUIRequest) -> String {
        guard let trimmed = request.title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return String(localized: "Extension")
        }
        return trimmed
    }

    /// "Expires in about N seconds" for a request with a deadline.
    static func timeoutSummary(of request: ExtensionUIRequest, now: Date = Date()) -> String? {
        let remainingSeconds: Int
        if let timeoutAt = request.timeoutAt {
            remainingSeconds = max(1, Int(ceil(timeoutAt.timeIntervalSince(now))))
        } else if let timeout = request.timeout, timeout > 0 {
            remainingSeconds = max(1, (timeout + 999) / 1000)
        } else {
            return nil
        }
        return String(localized: "Expires in about \(remainingSeconds) seconds")
    }

    // MARK: Lifecycle

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        isVisible = true
        // The sheet's navigation controller is what UIKit asks about a swipe.
        navigationController?.isModalInPresentation = true
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        isVisible = false
    }

    // MARK: Rows

    override func sections() -> [ListSection<Section, Item>] {
        var sections: [ListSection<Section, Item>] = []
        if let message = request.message, !message.isEmpty {
            sections.append(ListSection(.message, items: [.message]))
        }
        sections.append(ListSection(.unsupported, items: [.unsupported]))
        if Self.timeoutSummary(of: request) != nil {
            sections.append(ListSection(.timeout, items: [.timeout]))
        }
        return sections
    }

    override func inputs(of item: Item) -> AnyHashable {
        switch item {
        case .message: AnyHashable(request.message ?? "")
        case .unsupported: AnyHashable(request.method)
        case .timeout: AnyHashable(Self.timeoutSummary(of: request) ?? "")
        }
    }

    override func copyText(of item: Item) -> String? {
        item == .message ? request.message : nil
    }

    override func configure(_ cell: UICollectionViewListCell, item: Item) {
        switch item {
        case .message:
            var content = content(.plain)
            content.text = request.message
            content.textProperties.font = .preferredFont(forTextStyle: .body)
            cell.contentConfiguration = content
            cell.accessibilityIdentifier = "extension.dialog.message"
        case .unsupported:
            cell.contentConfiguration = UIContentUnavailableConfiguration.loadState(
                .empty(
                    title: String(localized: "Unsupported extension UI"),
                    systemImage: "questionmark.app",
                    message: String(
                        localized: "This extension asked for \"\(request.method)\". Cancel and try the task another way."
                    )
                ),
                palette: ThemeRuntimeState.currentPalette()
            )
            cell.accessibilityIdentifier = "extension.dialog.unsupported"
        case .timeout:
            let style = SettingsStyle.current
            var content = content(.plain)
            content.text = Self.timeoutSummary(of: request)
            content.textProperties.color = style.value
            content.image = UIImage(systemName: "timer")
            content.imageProperties.tintColor = style.value
            cell.contentConfiguration = content
            cell.accessibilityIdentifier = "extension.dialog.timeout"
        }
    }

    // MARK: Answer

    private func cancelRequest() {
        guard !isSubmitting else { return }
        isSubmitting = true
        cancelItem.isEnabled = false
        Task { @MainActor in
            do {
                try await connection.respondToExtensionUI(
                    id: request.id,
                    sessionId: request.sessionId,
                    payload: .cancelled
                )
                if isVisible { Router.finish(self) }
            } catch {
                isSubmitting = false
                cancelItem.isEnabled = true
                connection.extensionToast = "Failed to cancel: \(error.localizedDescription)"
            }
        }
    }
}
