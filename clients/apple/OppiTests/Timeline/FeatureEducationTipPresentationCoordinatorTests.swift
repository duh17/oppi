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

    @Test func repeatedClaimReleaseAndCompletionOperationsKeepSinglePresentationInvariant() throws {
        let (coordinator, defaults) = try makeCoordinator()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let tipIDs = [
            FeatureEducationTips.openToolDetails.id,
            FeatureEducationTips.toolOutputShortcuts.id,
            FeatureEducationTips.changedFilesBar.id,
            FeatureEducationTips.answerPrompt.id,
            FeatureEducationTips.busySendMode.id,
            FeatureEducationTips.reviewCommentSelection.id,
        ]
        let owners = (0..<5).map { _ in UUID() }
        var rng = DeterministicGenerator(seed: 0xF00D_CAFE)
        var shownTipIDs = Set<String>()

        for _ in 0..<240 {
            let tipID = tipIDs[Int(rng.next() % UInt64(tipIDs.count))]
            let ownerID = owners[Int(rng.next() % UInt64(owners.count))]

            switch rng.next() % 4 {
            case 0:
                let wasActive = coordinator.activePresentation
                let claimed = coordinator.claim(tipID: tipID, ownerID: ownerID)
                if wasActive == nil {
                    #expect(claimed == !shownTipIDs.contains(tipID))
                    if claimed {
                        shownTipIDs.insert(tipID)
                    }
                } else {
                    #expect(
                        claimed == (wasActive == FeatureEducationTipPresentationCoordinator.ActivePresentation(
                            tipID: tipID,
                            ownerID: ownerID
                        ))
                    )
                }
            case 1:
                let wasActive = coordinator.activePresentation
                let claimed = coordinator.claim(tipID: tipID, ownerID: ownerID, force: true)
                #expect(claimed == (wasActive == nil || wasActive == FeatureEducationTipPresentationCoordinator.ActivePresentation(
                    tipID: tipID,
                    ownerID: ownerID
                )))
            case 2:
                coordinator.release(tipID: tipID, ownerID: ownerID)
            default:
                coordinator.markCompleted(tipID: tipID)
                shownTipIDs.insert(tipID)
            }

            if let active = coordinator.activePresentation {
                #expect(tipIDs.contains(active.tipID))
                #expect(owners.contains(active.ownerID))
            }
        }

        for tipID in shownTipIDs {
            #expect(!coordinator.claim(tipID: tipID, ownerID: owners[0]))
        }
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

private struct DeterministicGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}
