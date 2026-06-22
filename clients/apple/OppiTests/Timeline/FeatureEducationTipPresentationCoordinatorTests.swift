import Foundation
import Testing
@testable import Oppi

@MainActor
@Suite("Feature education tip presentation coordinator")
struct FeatureEducationTipPresentationCoordinatorTests {
    @Test func claimAllowsOnlyOneVisibleTipAndConsumesShownTip() throws {
        let (coordinator, defaults) = try makeCoordinator()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let firstOwner = UUID()
        let secondOwner = UUID()

        #expect(coordinator.claim(tipID: "open-tool-details", ownerID: firstOwner))
        #expect(!coordinator.claim(tipID: "answer-prompt", ownerID: secondOwner))

        coordinator.release(tipID: "open-tool-details", ownerID: firstOwner)

        #expect(!coordinator.claim(tipID: "open-tool-details", ownerID: firstOwner))
        #expect(coordinator.claim(tipID: "answer-prompt", ownerID: secondOwner))
    }

    @Test func forceClaimDoesNotConsumeShownTip() throws {
        let (coordinator, defaults) = try makeCoordinator()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let owner = UUID()
        #expect(coordinator.claim(tipID: "review-selection", ownerID: owner, force: true))
        coordinator.release(tipID: "review-selection", ownerID: owner)

        #expect(coordinator.claim(tipID: "review-selection", ownerID: owner))
    }

    @Test func completedTipReleasesActivePresentation() throws {
        let (coordinator, defaults) = try makeCoordinator()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let owner = UUID()
        #expect(coordinator.claim(tipID: "tool-output-shortcuts", ownerID: owner))

        coordinator.markCompleted(tipID: "tool-output-shortcuts")

        #expect(coordinator.activePresentation == nil)
        #expect(!coordinator.claim(tipID: "tool-output-shortcuts", ownerID: owner))
    }
}

private let defaultsSuiteName = "FeatureEducationTipPresentationCoordinatorTests"

@MainActor
private func makeCoordinator() throws -> (FeatureEducationTipPresentationCoordinator, UserDefaults) {
    let defaults = try #require(UserDefaults(suiteName: defaultsSuiteName))
    defaults.removePersistentDomain(forName: defaultsSuiteName)
    let store = FeatureEducationTipPresentationStore(
        defaults: defaults,
        namespace: UUID().uuidString
    )
    return (FeatureEducationTipPresentationCoordinator(store: store), defaults)
}
