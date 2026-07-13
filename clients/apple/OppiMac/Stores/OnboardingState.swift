import Foundation
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "OppiMac", category: "OnboardingState")

/// State machine for the first-run onboarding wizard.
///
/// Steps: prerequisites -> permissions -> serverInit -> done.
///
/// Pairing an iPhone or iPad is optional companion setup. The Mac app can run
/// or attach to the local server without any paired mobile device.
/// Persists completion so the wizard only runs once.
@MainActor @Observable
final class OnboardingState {

    // MARK: - Types

    enum Step: Int, CaseIterable, Sendable, Comparable {
        case prerequisites
        case permissions
        case serverInit
        case done

        static func < (lhs: Step, rhs: Step) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        var title: String {
            switch self {
            case .prerequisites: "Prerequisites"
            case .permissions: "Permissions"
            case .serverInit: "Server Setup"
            case .done: "Done"
            }
        }
    }

    // MARK: - Public state

    private(set) var currentStep: Step = .prerequisites
    private(set) var needsOnboarding: Bool = false

    // MARK: - First-run detection

    /// Check whether local configuration or the npm-installed CLI still needs setup.
    func checkFirstRun(
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        cliAvailable: () -> Bool = { ServerProcessManager.resolveServerCLIPath() != nil }
    ) {
        let configPath = NSString("~/.config/oppi/config.json").expandingTildeInPath
        let configExists = fileExists(configPath)
        let hasCLI = cliAvailable()
        needsOnboarding = !configExists || !hasCLI
        logger.info(
            "First-run check: config exists=\(configExists), CLI available=\(hasCLI), needs onboarding=\(self.needsOnboarding)"
        )
    }

    // MARK: - Navigation

    /// Advance to the next step. No-op if already at .done.
    func advance() {
        guard let nextIndex = Step.allCases.firstIndex(of: currentStep)
            .map({ Step.allCases.index(after: $0) }),
              nextIndex < Step.allCases.endIndex else {
            return
        }
        let next = Step.allCases[nextIndex]
        logger.info("Onboarding: \(self.currentStep.title) -> \(next.title)")
        if next == .done {
            completeOnboarding()
        } else {
            currentStep = next
        }
    }

    /// Go back one step. No-op if at the first step.
    func goBack() {
        guard let currentIndex = Step.allCases.firstIndex(of: currentStep),
              currentIndex > Step.allCases.startIndex else {
            return
        }
        currentStep = Step.allCases[Step.allCases.index(before: currentIndex)]
    }

    /// Mark onboarding as complete.
    func completeOnboarding() {
        currentStep = .done
        needsOnboarding = false
        logger.info("Onboarding completed")
    }

    /// Reset to the beginning (for testing or re-running).
    func reset() {
        currentStep = .prerequisites
        needsOnboarding = true
    }
}
