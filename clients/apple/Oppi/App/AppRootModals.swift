import UIKit

/// The app-wide modals of the window root, presented over whatever the window
/// shows: the extension dialog (`ServerConnection.activeExtensionDialog`), the
/// notice (`extensionToast`), and What's New (`AppNavigation.showWhatsNew`).
/// Each is a router modal slot on `anchor`, set from that state in the owner's
/// `updateProperties()`, so the owner runs again when any of it changes. A
/// slot's `clear` writes the state back (nil, nil, false) once its modal is
/// gone, however it went: the dialog and notice answer or close themselves, a
/// notice can be swiped down.
///
/// The state belongs to the *active* connection. The dialog's slot id names
/// that connection, so a dialog left up on a server that is no longer active
/// closes without answering (it is still that connection's to answer), and
/// another server's dialog opens in its place.
@MainActor
final class AppRootModals {
    /// The dialog slot's identity: the request, on its connection.
    struct DialogID: Hashable {
        let connection: ObjectIdentifier
        let request: String
    }

    private let root: AppRootEnvironment
    private let dialog = RouterModalPresenter()
    private let notice = RouterModalPresenter()
    private let whatsNew = RouterModalPresenter()

    init(root: AppRootEnvironment, anchor: UIViewController) {
        self.root = root
        dialog.anchor = anchor
        notice.anchor = anchor
        whatsNew.anchor = anchor
    }

    /// Reads the state behind the three slots, so the anchor's
    /// `updateProperties()` runs again when it changes.
    func update() {
        let connection = root.coordinator.activeConnection
        updateDialog(connection: connection)
        updateNotice(connection: connection)
        updateWhatsNew()
    }

    /// The anchor is in a window: a modal asked for earlier can present now.
    func anchorDidAppear() {
        for slot in [dialog, notice, whatsNew] {
            slot.sync()
        }
    }

    // MARK: Extension dialog

    /// The dialog this sheet shows. Ask cards render in the chat instead.
    static func sheetRequest(_ request: ExtensionUIRequest?) -> ExtensionUIRequest? {
        guard let request else { return nil }
        switch request.nativePresentation {
        case .editorSheet, .fallbackSheet:
            return request
        case .askCard, .inlineAskCard:
            return nil
        }
    }

    /// Editor and fallback both use the router's navigation. Neither shows a grabber.
    static func dialogPresentation(for request: ExtensionUIRequest) -> ModalPresentation {
        switch request.nativePresentation {
        case .fallbackSheet:
            .sheet.detents([.medium(), .large()]).inNavigation()
        default:
            .sheet.detents([.large()]).inNavigation()
        }
    }

    private func updateDialog(connection: ServerConnection) {
        let request = Self.sheetRequest(connection.activeExtensionDialog)
        let root = root
        dialog.update(
            id: request.map { DialogID(connection: ObjectIdentifier(connection), request: $0.id) },
            presentation: request.map(Self.dialogPresentation(for:)) ?? .sheet.inNavigation(),
            root: root,
            clear: { [weak connection] in connection?.activeExtensionDialog = nil },
            screen: {
                guard let request else { return .controller({ UIViewController() }) }
                // The editor keeps what the person typed; the fallback shows the
                // request, so a replacement under the same id redraws it.
                if request.nativePresentation == .editorSheet {
                    return .controller({ ExtensionEditorComposer.make(request: request, connection: connection) })
                }
                return .liveController({
                    ExtensionDialogFallbackViewController(request: request, connection: connection, root: root)
                }, update: { screen in
                    screen.update(request: request)
                })
            }
        )
    }

    // MARK: Notice

    static let noticePresentation = ModalPresentation.sheet
        .detents([.custom { $0.maximumDetentValue * 0.35 }, .medium()])
        .inNavigation()

    private func updateNotice(connection: ServerConnection) {
        let message = connection.extensionToast
        let root = root
        notice.update(
            id: message == nil ? nil : "notice",
            presentation: Self.noticePresentation,
            root: root,
            clear: { [weak connection] in connection?.extensionToast = nil },
            screen: {
                .liveController({
                    ExtensionNoticeViewController(message: message ?? "", root: root)
                }, update: { screen in
                    if let message { screen.update(message: message) }
                })
            }
        )
    }

    // MARK: What's New

    private func updateWhatsNew() {
        let navigation = root.navigation
        whatsNew.update(
            id: navigation.showWhatsNew ? "whatsNew" : nil,
            presentation: .fullScreen,
            root: root,
            clear: { navigation.showWhatsNew = false },
            // Full screen covers the anchor, which then stops updating, so the
            // screen closes itself instead of waiting for the cleared flag.
            screen: { .controller({ WhatsNewViewController { Router.finish($0) } }) }
        )
    }
}
