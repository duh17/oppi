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

    var allowsRemoteDiagnosticsUpload: Bool {
        self == .internalDiagnostics
    }

    var sentryEnvironmentName: String {
#if DEBUG
        return "debug"
#else
        switch self {
        case .public:
            return "release"
        case .internalDiagnostics:
            return "test"
        }
#endif
    }

    var label: String {
        switch self {
        case .public:
            return "public"
        case .internalDiagnostics:
            return "internal"
        }
    }
}

enum TelemetrySettings {
    static var mode: TelemetryMode {
        TelemetryMode.current
    }

    static var allowsRemoteDiagnosticsUpload: Bool {
        allowsRemoteDiagnosticsUpload(
            mode: mode,
            environment: ProcessInfo.processInfo.environment
        )
    }

    static var sentryEnvironmentName: String {
        mode.sentryEnvironmentName
    }

    static func allowsRemoteDiagnosticsUpload(
        mode: TelemetryMode,
        environment: [String: String]
    ) -> Bool {
        guard mode.allowsRemoteDiagnosticsUpload else {
            return false
        }
        return !isRunningAutomatedTests(environment: environment)
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
