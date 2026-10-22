import SwiftUI
import TipKit
import Testing
import UIKit
@testable import Oppi

@MainActor
@Suite("Feature education tip host")
struct FeatureEducationTipHostViewTests {
    private struct HostedTip: Tip {
        var title: Text { Text("Hosted tip") }
    }

    private static let hostedDescriptor = FeatureEducationTipDescriptor(
        id: "tip-host-test",
        title: "Hosted tip",
        message: "Hosted",
        systemImageName: "star"
    )

    /// Leaving a chat while its tip is shown destroys the host without a
    /// `stop()`. The claim must go with it, or no other tip shows until relaunch.
    @Test func destroyedHostGivesBackItsClaimSoAnotherTipCanShow() async throws {
        let coordinator = FeatureEducationTipPresentationCoordinator.shared
        coordinator.resetForTesting()
        defer { coordinator.resetForTesting() }

        var host: FeatureEducationTipHostView? = FeatureEducationTipHostView(
            tip: HostedTip(),
            descriptor: Self.hostedDescriptor,
            insets: .zero
        )
        host?.start()
        // TipKit reports eligibility asynchronously; a loaded machine can take a while.
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
