import SwiftUI
import UIKit

/// When auxiliary side content opens as a trailing column instead of a sheet.
///
/// Chat keeps an explicit sheet unless a vertical toolbar edge is present and
/// the width is regular. These surfaces follow the width half of that rule:
/// a trailing column in regular width, the existing sheet or stack in compact.
/// The rail edge is not required. iPad and Duo's inner portrait are regular
/// without a vertical bar, and folding must not turn an open column back into
/// a sheet. Compact, including Duo's cover display, keeps the sheet so a
/// column does not adapt into a second one.
enum TrailingSidePanelPolicy {
    static func usesTrailingColumn(horizontalSizeClass: UserInterfaceSizeClass?) -> Bool {
        horizontalSizeClass == .regular
    }
}

extension View {
    /// A side panel in a trailing column beside this view, hosted by UIKit.
    /// Replaces SwiftUI `.inspector`, under the screen's navigation bar like
    /// an inspector inside a navigation stack.
    ///
    /// `item` shows the column; nil hides it. The caller applies
    /// `TrailingSidePanelPolicy` and, at compact width, presents the same
    /// panel with `routerModal` instead. The panel is a `HostFactory` screen
    /// at the root of the column's own `RouterNavigationController`, for its
    /// title and bar items; it pushes and searches through its
    /// `ScreenNavigator`. A new `item.id` replaces the panel.
    ///
    /// The panel must not bring its own SwiftUI `NavigationStack`: the column
    /// is a child controller, and a stack hosted there reset an enclosing
    /// SwiftUI `NavigationStack` (the screen's own, until the shell is UIKit)
    /// to its root.
    ///
    /// The panel content runs in its own graph with the app root services.
    /// Presenter-local values (server scope, review scope, bindings into an
    /// `@Observable`) go on `content` explicitly. Close it through the
    /// caller's state: the column is neither pushed nor presented, so
    /// `ScreenNavigator.finish()` has nothing to close.
    func routerTrailingColumn<Item: Identifiable, Panel: View>(
        item: Item?,
        minWidth: CGFloat,
        idealWidth: CGFloat,
        @ViewBuilder content: @escaping (Item) -> Panel
    ) -> some View {
        HStack(spacing: 0) {
            frame(maxWidth: .infinity, maxHeight: .infinity)
            if let item {
                Divider()
                    .ignoresSafeArea(.container, edges: .bottom)
                RouterTrailingColumnHost(id: AnyHashable(item.id)) {
                    AnyView(content(item))
                }
                // Up to the ideal width; narrower windows split the space,
                // down to the minimum.
                .frame(minWidth: minWidth, idealWidth: idealWidth, maxWidth: idealWidth)
                .ignoresSafeArea(.container, edges: .bottom)
            }
        }
    }
}

private struct RouterTrailingColumnHost: UIViewControllerRepresentable {
    let id: AnyHashable
    let makeContent: () -> AnyView
    @Environment(\.appRootEnvironment) private var root

    func makeUIViewController(context: Context) -> TrailingColumnController {
        TrailingColumnController()
    }

    func updateUIViewController(_ column: TrailingColumnController, context: Context) {
        guard let root else {
            preconditionFailure("routerTrailingColumn needs appRootEnvironment(_:) above its view")
        }
        column.show(id: id, root: root, content: makeContent)
    }
}

/// UIKit owner of a trailing column's panel: one hosted screen at the root of
/// the column's own navigation controller.
final class TrailingColumnController: UIViewController {
    private var panelID: AnyHashable?
    private var screen: HostedScreenController?
    private var container: RouterNavigationController?

    override func loadView() {
        let view = UIView()
        view.backgroundColor = .clear
        self.view = view
    }

    func show(
        id: AnyHashable,
        root: AppRootEnvironment,
        content: @escaping () -> AnyView
    ) {
        if id == panelID, let screen {
            // The presenter re-rendered: refresh the content it builds.
            screen.setContent(content)
            return
        }
        removeContainer()

        let screen = HostFactory.screen(root: root, content: content)
        let container = RouterNavigationController(rootViewController: screen)
        let themeStore = root.themeStore
        container.interfaceStyle = { themeStore.userInterfaceStyle }

        addChild(container)
        container.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(container.view)
        NSLayoutConstraint.activate([
            container.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            container.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            container.view.topAnchor.constraint(equalTo: view.topAnchor),
            container.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        container.didMove(toParent: self)

        panelID = id
        self.screen = screen
        self.container = container
    }

    private func removeContainer() {
        guard let container else { return }
        container.willMove(toParent: nil)
        container.view.removeFromSuperview()
        container.removeFromParent()
        self.container = nil
        screen = nil
        panelID = nil
    }
}
