import Foundation

enum TelemetryMode: Sendable, Equatable {
    case `public`
    case internalDiagnostics

    static var current: Self {
        Self.fromInfoValue(Bundle.main.object(forInfoDictionaryKey: "OPPITelemetryMode"))
    }

    static func fromInfoValue(_ value: Any?) -> Self {
        if let raw = value as? String {
            return Self.fromRawString(raw)
        }

        if let number = value as? NSNumber {
            return number.boolValue ? .internalDiagnostics : .public
        }

        return Self.defaultMode
    }

    static func fromRawString(_ raw: String?) -> Self {
        guard let raw else { return Self.defaultMode }

        let normalized = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard !normalized.isEmpty else { return Self.defaultMode }

        switch normalized {
        case "internal", "debug", "test", "qa", "staging", "dev", "development", "enabled", "on", "true", "1":
            return .internalDiagnostics
        case "public", "release", "prod", "production", "off", "disabled", "none", "false", "0":
            return .public
        default:
            return Self.defaultMode
        }
    }

    private static var defaultMode: Self {
        .internalDiagnostics
    }

    var diagnosticsEnabledByDefault: Bool {
        self == .internalDiagnostics
    }
}

enum TelemetrySettings {
    static var mode: TelemetryMode {
        TelemetryMode.current
    }

    static var allowsRemoteDiagnosticsUpload: Bool {
        allowsRemoteDiagnosticsUpload(
            mode: mode,
            userOptIn: AppPreferences.Telemetry.isEnabled,
            environment: ProcessInfo.processInfo.environment
        )
    }

    static func allowsRemoteDiagnosticsUpload(
        mode: TelemetryMode,
        userOptIn: Bool? = nil,
        environment: [String: String]
    ) -> Bool {
        if isRunningAutomatedTests(environment: environment) {
            return false
        }

        // Callers may supply an explicit preference for deterministic tests.
        // An unset preference preserves the build defaults: on for internal
        // builds and off for public builds.
        return userOptIn ?? mode.diagnosticsEnabledByDefault
    }

    private static func isRunningAutomatedTests(environment: [String: String]) -> Bool {
        if let xctestConfigurationPath = environment["XCTestConfigurationFilePath"],
           !xctestConfigurationPath.isEmpty {
            return true
        }

        if let injectedBundlePath = environment["XCTestBundlePath"],
           !injectedBundlePath.isEmpty {
            return true
        }

        return false
    }
}
