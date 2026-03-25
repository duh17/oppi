import Testing
import Foundation
@testable import Oppi

@Suite("OnboardingState")
@MainActor
struct OnboardingStateTests {

    // MARK: - Step advancement (parameterized)

    @Test("advance moves through each step in order",
          arguments: zip(
            [OnboardingState.Step.prerequisites, .permissions, .serverInit, .pairing],
            [OnboardingState.Step.permissions, .serverInit, .pairing, .done]
          ))
    func advanceStep(from current: OnboardingState.Step, expected next: OnboardingState.Step) {
        let state = OnboardingState()
        // Navigate to the starting step.
        while state.currentStep != current { state.advance() }

        state.advance()

        #expect(state.currentStep == next)
    }

    @Test func advanceFromDoneIsNoOp() {
        let state = OnboardingState()
        state.completeOnboarding()
        #expect(state.currentStep == .done)

        state.advance()

        #expect(state.currentStep == .done)
    }

    // MARK: - Step go-back (parameterized)

    @Test("goBack returns to previous step",
          arguments: zip(
            [OnboardingState.Step.permissions, .serverInit, .pairing, .done],
            [OnboardingState.Step.prerequisites, .permissions, .serverInit, .pairing]
          ))
    func goBackStep(from current: OnboardingState.Step, expected previous: OnboardingState.Step) {
        let state = OnboardingState()
        while state.currentStep != current { state.advance() }

        state.goBack()

        #expect(state.currentStep == previous)
    }

    @Test func goBackFromPrerequisitesIsNoOp() {
        let state = OnboardingState()
        #expect(state.currentStep == .prerequisites)

        state.goBack()

        #expect(state.currentStep == .prerequisites)
    }

    // MARK: - Complete / reset

    @Test func completeOnboardingSetsStateCorrectly() {
        let state = OnboardingState()
        state.reset() // ensure needsOnboarding is true
        #expect(state.needsOnboarding)

        state.completeOnboarding()

        #expect(state.currentStep == .done)
        #expect(!state.needsOnboarding)
    }

    @Test func resetResetsState() {
        let state = OnboardingState()
        state.completeOnboarding()
        #expect(!state.needsOnboarding)

        state.reset()

        #expect(state.currentStep == .prerequisites)
        #expect(state.needsOnboarding)
    }

    // MARK: - Round-trip: advance all then go back all

    @Test func fullRoundTrip() {
        let state = OnboardingState()
        let allSteps = OnboardingState.Step.allCases

        // Advance through all
        for i in 0..<(allSteps.count - 1) {
            #expect(state.currentStep == allSteps[i])
            state.advance()
        }
        #expect(state.currentStep == .done)

        // Go back through all
        for i in stride(from: allSteps.count - 1, through: 1, by: -1) {
            #expect(state.currentStep == allSteps[i])
            state.goBack()
        }
        #expect(state.currentStep == .prerequisites)
    }

    // MARK: - Step ordering (Comparable)

    @Test("Step ordering is correct",
          arguments: [
            (OnboardingState.Step.prerequisites, OnboardingState.Step.permissions),
            (.permissions, .serverInit),
            (.serverInit, .pairing),
            (.pairing, .done),
          ])
    func stepOrdering(earlier: OnboardingState.Step, later: OnboardingState.Step) {
        #expect(earlier < later)
        #expect(!(later < earlier))
    }

    // MARK: - Step titles

    @Test("Every step has a non-empty title",
          arguments: OnboardingState.Step.allCases)
    func stepTitleNotEmpty(step: OnboardingState.Step) {
        #expect(!step.title.isEmpty)
    }
}
