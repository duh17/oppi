import Testing
@testable import Oppi

@Suite("Telemetry mode")
struct TelemetryModeTests {
    @Test func internalAliasesEnableRemoteDiagnostics() {
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
            #expect(mode.allowsRemoteDiagnosticsUpload)
        }
    }

    @Test func publicAliasesDisableRemoteDiagnostics() {
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
            #expect(!mode.allowsRemoteDiagnosticsUpload)
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

    // MARK: - User opt-in for release builds

    @Test func publicModeAllowsUploadWhenUserOptsIn() {
        #expect(
            TelemetrySettings.allowsRemoteDiagnosticsUpload(
                mode: .public,
                userOptIn: true,
                environment: [:]
            )
        )
    }

    @Test func publicModeDeniesUploadWhenUserDoesNotOptIn() {
        #expect(
            !TelemetrySettings.allowsRemoteDiagnosticsUpload(
                mode: .public,
                userOptIn: false,
                environment: [:]
            )
        )
    }

    @Test func internalModeAlwaysAllowsRegardlessOfOptIn() {
        #expect(
            TelemetrySettings.allowsRemoteDiagnosticsUpload(
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
