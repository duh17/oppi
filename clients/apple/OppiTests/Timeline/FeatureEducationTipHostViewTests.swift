import Foundation
import Testing
import UIKit
@testable import Oppi

@MainActor
@Suite("Feature education tip host")
struct FeatureEducationTipHostViewTests {
    private static let defaultsSuiteName = "FeatureEducationTipHostViewTests"

    private static let hostedDescriptor = FeatureEducationTipDescriptor(
        id: "tip-host-test",
        title: "Hosted tip",
        message: "Hosted",
        systemImageName: "star"
    )

    /// This suite is about the claim a host takes and gives back, not about
    /// TipKit's datastore, so its tip is always eligible.
    private static let alwaysEligible = FeatureEducationTipPresenter(
        shouldDisplay: { _ in true },
        displayUpdates: { _ in AsyncStream<Bool> { $0.yield(true) } },
        invalidate: { _, _ in }
    )

    /// Leaving a chat while its tip is shown destroys the host without a
    /// `stop()`. The claim must go with it, or no other tip shows until relaunch.
    @Test func destroyedHostGivesBackItsClaimSoAnotherTipCanShow() async throws {
        // A private coordinator: other suites claim the shared one while this
        // test waits for its host.
        let defaults = try #require(UserDefaults(suiteName: Self.defaultsSuiteName))
        defaults.removePersistentDomain(forName: Self.defaultsSuiteName)
        defer { defaults.removePersistentDomain(forName: Self.defaultsSuiteName) }
        let coordinator = FeatureEducationTipPresentationCoordinator(
            store: FeatureEducationTipPresentationStore(defaults: defaults, namespace: UUID().uuidString)
        )

        var host: FeatureEducationTipHostView? = FeatureEducationTipHostView(
            descriptor: Self.hostedDescriptor,
            insets: .zero,
            coordinator: coordinator,
            presenter: Self.alwaysEligible
        )
        host?.start()
        // The host claims from the task it starts, so the claim lands after this.
        for _ in 0..<500 where coordinator.activePresentation == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(coordinator.activePresentation?.tipID == Self.hostedDescriptor.id)
        #expect(!coordinator.claim(tipID: FeatureEducationTips.busySendMode.id, ownerID: UUID()))

        host = nil

        #expect(coordinator.activePresentation == nil)
        #expect(coordinator.claim(tipID: FeatureEducationTips.busySendMode.id, ownerID: UUID()))
    }
}
