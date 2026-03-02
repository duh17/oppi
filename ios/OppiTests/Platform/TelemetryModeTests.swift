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
}
