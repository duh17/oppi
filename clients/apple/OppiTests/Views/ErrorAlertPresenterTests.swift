import Testing
import UIKit
@testable import Oppi

/// A screen whose error is state, the way the Agent, Schedule, and Pi screens
/// hold theirs: `updateProperties()` syncs it, OK clears what the person read.
@MainActor
private final class StateErrorScreen: UIViewController {
    var error: String? {
        didSet { setNeedsUpdateProperties() }
    }

    override func updateProperties() {
        super.updateProperties()
        errorAlerts.sync(title: "Agent", message: error) { [weak self] shown in
            if self?.error == shown { self?.error = nil }
        }
    }
}

@Suite("Error alerts and confirmations", .serialized)
@MainActor
struct ErrorAlertPresenterTests {
    private func mount(_ screen: UIViewController) throws -> (window: UIWindow, navigation: UINavigationController) {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let navigation = UINavigationController(rootViewController: screen)
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        return (window, navigation)
    }

    /// The alert over the window, once nothing is mid-transition.
    private func settledAlert(in window: UIWindow) async -> UIAlertController? {
        var found: UIAlertController?
        _ = await waitForMainActorCondition(timeout: .seconds(5)) {
            guard let alert = window.rootViewController?.presentedViewController as? UIAlertController,
                  !alert.isBeingPresented else { return false }
            found = alert
            return true
        }
        return found
    }

    /// Taps a button the way UIKit does: the alert closes, then the handler runs.
    private func tap(_ title: String, on alert: UIAlertController) async throws {
        let action = try #require(alert.actions.first { $0.title == title })
        typealias Handler = @convention(block) (UIAlertAction) -> Void
        let block = unsafeBitCast(try #require(action.value(forKey: "handler") as AnyObject?), to: Handler.self)
        alert.dismiss(animated: false)
        block(action)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { alert.presentingViewController == nil })
    }

    // MARK: - sync (an error held in state)

    @Test func aNewerErrorReplacesTheShownOneAndOKClearsOnlyThatOne() async throws {
        let screen = StateErrorScreen()
        let (window, _) = try mount(screen)
        defer { hideTestWindow(window) }

        screen.error = "first"
        screen.updatePropertiesIfNeeded()
        let alert = try #require(await settledAlert(in: window))
        #expect(alert.message == "first")

        screen.error = "second"
        screen.updatePropertiesIfNeeded()
        #expect(alert.message == "second", "the newer error is the one on screen, not dropped")
        #expect(window.rootViewController?.presentedViewController === alert, "one alert, never stacked")

        try await tap("OK", on: alert)
        #expect(screen.error == nil, "OK clears the error the person read")
    }

    @Test func okNeverClearsAnErrorThatArrivedAfterTheOneItClosed() async throws {
        let screen = StateErrorScreen()
        let (window, _) = try mount(screen)
        defer { hideTestWindow(window) }

        screen.error = "first"
        screen.updatePropertiesIfNeeded()
        let alert = try #require(await settledAlert(in: window))

        // The newer error is set but the screen has not run its pass yet when OK lands.
        screen.error = "second"
        try await tap("OK", on: alert)

        #expect(screen.error == "second", "the owner keeps an error the person never read")
        screen.updatePropertiesIfNeeded()
        let next = try #require(await settledAlert(in: window))
        #expect(next.message == "second", "and it is shown next")
    }

    @Test func clearingTheOwnersErrorClosesTheAlert() async throws {
        let screen = StateErrorScreen()
        let (window, _) = try mount(screen)
        defer { hideTestWindow(window) }
        screen.error = "first"
        screen.updatePropertiesIfNeeded()
        let alert = try #require(await settledAlert(in: window))

        screen.error = nil
        screen.updatePropertiesIfNeeded()

        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { alert.presentingViewController == nil })
    }

    // MARK: - show (an event) and holding while off the window

    @Test func aSecondErrorWhileOneShowsReplacesItsMessage() async throws {
        let screen = UIViewController()
        let (window, _) = try mount(screen)
        defer { hideTestWindow(window) }

        screen.errorAlerts.show(message: "disk full")
        let alert = try #require(await settledAlert(in: window))
        screen.errorAlerts.show(title: "Other", message: "quota exceeded")

        #expect(alert.message == "quota exceeded")
        #expect(alert.title == "Other")
        #expect(window.rootViewController?.presentedViewController === alert)
    }

    @Test func anErrorRaisedWhileTheScreenIsCoveredShowsWhenItIsBack() async throws {
        let screen = UIViewController()
        let (window, navigation) = try mount(screen)
        defer { hideTestWindow(window) }
        navigation.pushViewController(UIViewController(), animated: false)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { screen.viewIfLoaded?.window == nil })

        screen.errorAlerts.show(message: "raised while covered")
        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(200)) {
            window.rootViewController?.presentedViewController == nil
        }, "nothing shows over the page that covers the screen")

        navigation.popViewController(animated: false)
        let alert = try #require(await settledAlert(in: window))
        #expect(alert.message == "raised while covered")
    }

    @Test func anErrorHeldBeforeTheScreenHasAWindowShowsOnceItMounts() async throws {
        let screen = UIViewController()
        screen.errorAlerts.show(message: "raised before mounting")

        let (window, _) = try mount(screen)
        defer { hideTestWindow(window) }

        let alert = try #require(await settledAlert(in: window))
        #expect(alert.message == "raised before mounting")
    }

    @Test func aNewerHeldErrorReplacesAnOlderOne() async throws {
        let screen = UIViewController()
        screen.errorAlerts.show(message: "older")
        screen.errorAlerts.show(message: "newer")

        let (window, _) = try mount(screen)
        defer { hideTestWindow(window) }

        let alert = try #require(await settledAlert(in: window))
        #expect(alert.message == "newer")
    }

    @Test func dismissWithAPrefixTakesBackOnlyThatKindOfError() async throws {
        let screen = UIViewController()
        let (window, navigation) = try mount(screen)
        defer { hideTestWindow(window) }
        navigation.pushViewController(UIViewController(), animated: false)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { screen.viewIfLoaded?.window == nil })

        screen.errorAlerts.show(message: "Load failed: offline")
        screen.errorAlerts.dismiss(onlyWithPrefix: "Resume failed")
        navigation.popViewController(animated: false)
        let alert = try #require(await settledAlert(in: window))
        #expect(alert.message == "Load failed: offline", "another prefix leaves the held error")

        screen.errorAlerts.dismiss(onlyWithPrefix: "Load failed")
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { alert.presentingViewController == nil })
    }

    // MARK: - Confirmation

    @Test func aSheetWithNoRowInAWindowPointsAtTheScreen() async throws {
        let screen = UIViewController()
        let (window, _) = try mount(screen)
        defer { hideTestWindow(window) }
        let strayRow = UIView()

        let sheet = Confirmation(title: "Delete?", actionTitle: "Delete").present(from: screen, anchor: strayRow) {}

        let source = try #require(sheet.popoverPresentationController?.sourceView, "a popover always has a source")
        #expect(source === screen.view)
        #expect(sheet.popoverPresentationController?.permittedArrowDirections.isEmpty == true)
    }

    @Test func aSheetPointsAtTheRowThatAskedWhenItIsInAWindow() async throws {
        let screen = UIViewController()
        let (window, _) = try mount(screen)
        defer { hideTestWindow(window) }
        let row = UIView(frame: CGRect(x: 20, y: 100, width: 200, height: 44))
        screen.view.addSubview(row)

        let sheet = Confirmation(title: "Delete?", actionTitle: "Delete").present(from: screen, anchor: row) {}

        #expect(sheet.popoverPresentationController?.sourceView === row)
        #expect(sheet.popoverPresentationController?.sourceRect == row.bounds)
    }

    @Test func theActionRunsOnlyOnConfirmAndCancelReportsItself() async throws {
        let screen = UIViewController()
        let (window, _) = try mount(screen)
        defer { hideTestWindow(window) }
        var confirmed = 0
        var cancelled = 0
        let confirmation = Confirmation(title: "Delete?", actionTitle: "Delete", style: .alert)

        let first = confirmation.present(from: screen, anchor: nil, onConfirm: { confirmed += 1 }, onCancel: { cancelled += 1 })
        _ = await settledAlert(in: window)
        #expect(confirmed == 0, "asking runs nothing")
        try await tap("Cancel", on: first)
        #expect((confirmed, cancelled) == (0, 1))

        let second = confirmation.present(from: screen, anchor: nil, onConfirm: { confirmed += 1 }, onCancel: { cancelled += 1 })
        _ = await settledAlert(in: window)
        #expect(second.actions.map(\.style) == [.destructive, .cancel])
        try await tap("Delete", on: second)
        #expect((confirmed, cancelled) == (1, 1))
    }
}
