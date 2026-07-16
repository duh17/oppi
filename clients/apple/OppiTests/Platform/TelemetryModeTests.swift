import Testing
@testable import Oppi

@Suite("Telemetry mode")
struct TelemetryModeTests {
    @Test func internalAliasesDefaultDiagnosticsOn() {
        let enabledAliases = [
            "internal",
            "debug",
            "test",
            "qa",
            "staging",
            "dev",
            "development",
            "enabled",
            "on",
            "true",
            "1",
        ]

        for alias in enabledAliases {
            let mode = TelemetryMode.fromRawString(alias)
            #expect(mode == .internalDiagnostics)
            #expect(mode.diagnosticsEnabledByDefault)
        }
    }

    @Test func publicAliasesDefaultDiagnosticsOff() {
        let disabledAliases = [
            "public",
            "release",
            "prod",
            "production",
            "off",
            "disabled",
            "none",
            "false",
            "0",
        ]

        for alias in disabledAliases {
            let mode = TelemetryMode.fromRawString(alias)
            #expect(mode == .public)
            #expect(!mode.diagnosticsEnabledByDefault)
        }
    }

    @Test func emptyOrUnknownFallsBackToDefaultMode() {
        #expect(TelemetryMode.fromRawString(nil) == .internalDiagnostics)
        #expect(TelemetryMode.fromRawString("") == .internalDiagnostics)
        #expect(TelemetryMode.fromRawString("mystery") == .internalDiagnostics)
    }

    @Test func telemetrySettingsDisableRemoteUploadsDuringAutomatedTests() {
        #expect(
            !TelemetrySettings.allowsRemoteDiagnosticsUpload(
                mode: .internalDiagnostics,
                environment: ["XCTestConfigurationFilePath": "/tmp/test.xctestconfiguration"]
            )
        )
        #expect(
            !TelemetrySettings.allowsRemoteDiagnosticsUpload(
                mode: .internalDiagnostics,
                environment: ["XCTestBundlePath": "/tmp/OppiTests.xctest"]
            )
        )
    }

    @Test func telemetrySettingsStillRespectModeOutsideTests() {
        #expect(
            TelemetrySettings.allowsRemoteDiagnosticsUpload(
                mode: .internalDiagnostics,
                environment: [:]
            )
        )
        #expect(
            !TelemetrySettings.allowsRemoteDiagnosticsUpload(
                mode: .public,
                environment: [:]
            )
        )
    }

    // MARK: - Public mode metrics opt-in
    // Metrics upload to the user's own server is opt-in.

    @Test func publicModeAllowsMetricsWhenUserOptsIn() {
        #expect(
            TelemetrySettings.allowsRemoteDiagnosticsUpload(
                mode: .public,
                userOptIn: true,
                environment: [:]
            )
        )
    }

    @Test func publicModeDeniesMetricsWithoutOptIn() {
        #expect(
            !TelemetrySettings.allowsRemoteDiagnosticsUpload(
                mode: .public,
                userOptIn: false,
                environment: [:]
            )
        )
    }

    @Test func internalModeRespectsExplicitPreference() {
        #expect(
            !TelemetrySettings.allowsRemoteDiagnosticsUpload(
                mode: .internalDiagnostics,
                userOptIn: false,
                environment: [:]
            )
        )
        #expect(
            TelemetrySettings.allowsRemoteDiagnosticsUpload(
                mode: .internalDiagnostics,
                userOptIn: true,
                environment: [:]
            )
        )
    }

    @Test func telemetryPreferenceUsesBuildDefaultUntilExplicitlySet() {
        #expect(
            AppPreferences.Telemetry.resolvedEnabled(
                storedValue: nil,
                defaultEnabled: true
            )
        )
        #expect(
            !AppPreferences.Telemetry.resolvedEnabled(
                storedValue: nil,
                defaultEnabled: false
            )
        )
        #expect(
            !AppPreferences.Telemetry.resolvedEnabled(
                storedValue: false,
                defaultEnabled: true
            )
        )
        #expect(
            AppPreferences.Telemetry.resolvedEnabled(
                storedValue: true,
                defaultEnabled: false
            )
        )
    }

    @Test func automatedTestsBlockEvenWithOptIn() {
        #expect(
            !TelemetrySettings.allowsRemoteDiagnosticsUpload(
                mode: .public,
                userOptIn: true,
                environment: ["XCTestConfigurationFilePath": "/tmp/test.xctestconfiguration"]
            )
        )
        #expect(
            !TelemetrySettings.allowsRemoteDiagnosticsUpload(
                mode: .internalDiagnostics,
                userOptIn: true,
                environment: ["XCTestBundlePath": "/tmp/OppiTests.xctest"]
            )
        )
    }
}
