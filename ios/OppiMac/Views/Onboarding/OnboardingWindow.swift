import SwiftUI

/// Multi-step onboarding wizard for first-run setup.
///
/// Guides the user through: prerequisites check -> TCC permissions ->
/// server initialization -> iPhone pairing.
struct OnboardingWindow: View {

    let onboardingState: OnboardingState
    let permissionState: TCCPermissionState
    let processManager: ServerProcessManager
    let healthMonitor: ServerHealthMonitor
    let onComplete: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Progress indicator
            StepProgressBar(
                steps: OnboardingState.Step.allCases.filter { $0 != .done },
                current: onboardingState.currentStep
            )
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 8)

            Divider()

            // Step content
            Group {
                switch onboardingState.currentStep {
                case .prerequisites:
                    PrerequisitesView(onContinue: { onboardingState.advance() })

                case .permissions:
                    PermissionsStepView(
                        permissionState: permissionState,
                        onContinue: { onboardingState.advance() },
                        onBack: { onboardingState.goBack() }
                    )

                case .serverInit:
                    ServerInitView(
                        processManager: processManager,
                        healthMonitor: healthMonitor,
                        onContinue: { onboardingState.advance() },
                        onBack: { onboardingState.goBack() }
                    )

                case .pairing:
                    PairingView(
                        onDone: {
                            onboardingState.completeOnboarding()
                            onComplete()
                        }
                    )

                case .done:
                    // Should not be visible — onComplete dismisses the window
                    Text("Setup complete.")
                        .onAppear { onComplete() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 540, height: 440)
    }
}

// MARK: - Step progress bar

private struct StepProgressBar: View {

    let steps: [OnboardingState.Step]
    let current: OnboardingState.Step

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.element) { index, step in
                if index > 0 {
                    Rectangle()
                        .fill(step <= current ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(height: 2)
                }
                VStack(spacing: 4) {
                    Circle()
                        .fill(step <= current ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 10, height: 10)
                    Text(step.title)
                        .font(.caption2)
                        .foregroundStyle(step == current ? .primary : .secondary)
                }
            }
        }
    }
}
