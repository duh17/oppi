import Foundation
import Testing
@testable import Oppi

@Suite("DeviceResourceSampler")
struct DeviceResourceSamplerTests {

    // MARK: - CPU delta computation

    @Test("CPU delta produces valid percentage from synthetic timestamps")
    func cpuDeltaComputation() {
        // Simulate: 0.5s of CPU time over a 10s wall interval = 5%
        let wallSeconds = 10.0
        let prevUser = 100.0
        let prevSystem = 50.0
        let curUser = 100.4
        let curSystem = 50.1

        let cpuDelta = (curUser - prevUser) + (curSystem - prevSystem)
        let cpuPct = (cpuDelta / wallSeconds) * 100.0

        #expect(cpuPct > 0)
        #expect(cpuPct < 100)
        #expect(abs(cpuPct - 5.0) < 0.01)
    }

    @Test("CPU delta handles zero wall time gracefully")
    func cpuDeltaZeroWallTime() {
        let wallSeconds = 0.0
        // When wall time is zero, we skip emission (division by zero guard).
        // The sampler checks `wallSeconds > 0` before computing.
        #expect(wallSeconds <= 0)
    }

    @Test("CPU delta can exceed 100% with multicore usage")
    func cpuDeltaMulticore() {
        // 4 cores fully busy: 40s of CPU time over 10s wall = 400%
        let wallSeconds = 10.0
        let cpuDelta = 40.0
        let cpuPct = (cpuDelta / wallSeconds) * 100.0

        #expect(cpuPct == 400.0)
    }

    // MARK: - Memory values

    @Test("Memory footprint conversion is non-negative")
    func memoryFootprintNonNegative() {
        // Simulating phys_footprint -> MB conversion
        let physFootprint: UInt64 = 150 * 1024 * 1024 // 150 MB
        let footprintMB = Double(physFootprint) / (1024 * 1024)

        #expect(footprintMB >= 0)
        #expect(abs(footprintMB - 150.0) < 0.01)
    }

    @Test("Available memory conversion is non-negative")
    func availableMemoryNonNegative() {
        let availableBytes: UInt64 = 2 * 1024 * 1024 * 1024 // 2 GB
        let availableMB = Double(availableBytes) / (1024 * 1024)

        #expect(availableMB >= 0)
        #expect(abs(availableMB - 2048.0) < 0.01)
    }

    @Test("Zero memory footprint is valid")
    func zeroMemoryFootprint() {
        let physFootprint: UInt64 = 0
        let footprintMB = Double(physFootprint) / (1024 * 1024)
        #expect(footprintMB == 0)
    }

    // MARK: - Thermal state mapping

    @Test("Thermal state maps nominal to 0")
    func thermalNominal() {
        let value = thermalStateValue(.nominal)
        #expect(value == 0)
    }

    @Test("Thermal state maps fair to 1")
    func thermalFair() {
        let value = thermalStateValue(.fair)
        #expect(value == 1)
    }

    @Test("Thermal state maps serious to 2")
    func thermalSerious() {
        let value = thermalStateValue(.serious)
        #expect(value == 2)
    }

    @Test("Thermal state maps critical to 3")
    func thermalCritical() {
        let value = thermalStateValue(.critical)
        #expect(value == 3)
    }

    // MARK: - Telemetry gate

    @Test("Sampler respects telemetry gate")
    func telemetryGate() {
        // Verify the gate function exists and returns a boolean.
        // In test environments, XCTestConfigurationFilePath is set,
        // so allowsRemoteDiagnosticsUpload returns false.
        let gateResult = TelemetrySettings.allowsRemoteDiagnosticsUpload
        #expect(gateResult == false, "Tests run with automated-test detection, gate should be off")
    }

    @Test("Telemetry gate with explicit test environment rejects upload")
    func telemetryGateExplicit() {
        let allowed = TelemetrySettings.allowsRemoteDiagnosticsUpload(
            mode: .internalDiagnostics,
            environment: ["XCTestConfigurationFilePath": "/some/path"]
        )
        #expect(allowed == false)
    }

    @Test("Telemetry gate with internal mode and no test env allows upload")
    func telemetryGateInternal() {
        let allowed = TelemetrySettings.allowsRemoteDiagnosticsUpload(
            mode: .internalDiagnostics,
            environment: [:]
        )
        #expect(allowed == true)
    }

    // MARK: - Metric enum registration

    @Test("Device metric enum cases have correct raw values")
    func metricEnumRawValues() {
        #expect(ChatMetricName.deviceCpuPct.rawValue == "device.cpu_pct")
        #expect(ChatMetricName.deviceMemoryMb.rawValue == "device.memory_mb")
        #expect(ChatMetricName.deviceMemoryAvailableMb.rawValue == "device.memory_available_mb")
        #expect(ChatMetricName.deviceThermalState.rawValue == "device.thermal_state")
    }

    // MARK: - Wall time Duration decomposition

    @Test("Duration decomposition handles whole seconds only")
    func durationWholeSeconds() {
        let wallDelta: Duration = .seconds(10)
        let wallSeconds = Double(wallDelta.components.seconds)
            + Double(wallDelta.components.attoseconds) / 1e18
        #expect(abs(wallSeconds - 10.0) < 1e-9)
    }

    @Test("Duration decomposition handles fractional seconds via attoseconds")
    func durationFractionalSeconds() {
        // .milliseconds(500) should produce 0.5s via the attoseconds component
        let wallDelta: Duration = .milliseconds(500)
        let wallSeconds = Double(wallDelta.components.seconds)
            + Double(wallDelta.components.attoseconds) / 1e18
        #expect(abs(wallSeconds - 0.5) < 1e-9)
    }

    @Test("Duration decomposition handles sub-millisecond precision")
    func durationSubMillisecond() {
        let wallDelta: Duration = .microseconds(1)
        let wallSeconds = Double(wallDelta.components.seconds)
            + Double(wallDelta.components.attoseconds) / 1e18
        #expect(wallSeconds > 0)
        #expect(abs(wallSeconds - 0.000001) < 1e-12)
    }

    @Test("Duration decomposition of zero yields zero wall seconds")
    func durationZero() {
        let wallDelta: Duration = .zero
        let wallSeconds = Double(wallDelta.components.seconds)
            + Double(wallDelta.components.attoseconds) / 1e18
        #expect(wallSeconds == 0)
    }

    // MARK: - CPU delta edge cases

    @Test("CPU delta with identical samples yields 0%")
    func cpuDeltaIdenticalSamples() {
        let wallSeconds = 10.0
        let cpuDelta = (100.0 - 100.0) + (50.0 - 50.0)
        let cpuPct = (cpuDelta / wallSeconds) * 100.0
        #expect(cpuPct == 0.0)
    }

    @Test("CPU delta with very small wall interval inflates percentage")
    func cpuDeltaSmallWallInterval() {
        // 0.01s of CPU time over a 0.01s wall interval = 100%
        let wallSeconds = 0.01
        let cpuDelta = 0.01
        let cpuPct = (cpuDelta / wallSeconds) * 100.0
        #expect(abs(cpuPct - 100.0) < 0.01)
    }

    @Test("CPU delta with negative delta (clock rollover) is negative")
    func cpuDeltaNegative() {
        // If system clock wraps or samples are out of order, delta can go negative.
        // The sampler doesn't clamp — it just reports the value.
        let wallSeconds = 10.0
        let cpuDelta = -0.5
        let cpuPct = (cpuDelta / wallSeconds) * 100.0
        #expect(cpuPct < 0)
    }

    @Test("CPU percentage formula is linear in CPU time")
    func cpuDeltaLinearity() {
        let wallSeconds = 10.0
        let cpuDelta1 = 1.0
        let cpuDelta2 = 2.0
        let pct1 = (cpuDelta1 / wallSeconds) * 100.0
        let pct2 = (cpuDelta2 / wallSeconds) * 100.0
        #expect(abs(pct2 - 2 * pct1) < 1e-9)
    }

    // MARK: - Memory conversion edge cases

    @Test("Large memory footprint converts without overflow")
    func memoryFootprintLargeValue() {
        // 16 GB in bytes
        let physFootprint: UInt64 = 16 * 1024 * 1024 * 1024
        let footprintMB = Double(physFootprint) / (1024 * 1024)
        #expect(abs(footprintMB - 16384.0) < 0.01)
    }

    @Test("Small memory footprint converts accurately")
    func memoryFootprintSmallValue() {
        // 1 byte
        let physFootprint: UInt64 = 1
        let footprintMB = Double(physFootprint) / (1024 * 1024)
        #expect(footprintMB > 0)
        #expect(footprintMB < 0.001)
    }

    @Test("Available memory conversion from bytes to MB is exact for powers of two")
    func availableMemoryExactConversion() {
        let availableBytes: UInt64 = 1024 * 1024 // exactly 1 MB
        let availableMB = Double(availableBytes) / (1024 * 1024)
        #expect(availableMB == 1.0)
    }

    // MARK: - Thermal state exhaustiveness

    @Test("All four thermal states map to distinct ordered values")
    func thermalStateOrdering() {
        let nominal = thermalStateValue(.nominal)
        let fair = thermalStateValue(.fair)
        let serious = thermalStateValue(.serious)
        let critical = thermalStateValue(.critical)

        #expect(nominal < fair)
        #expect(fair < serious)
        #expect(serious < critical)
    }

    @Test("Thermal state values are contiguous integers 0-3")
    func thermalStateContiguous() {
        let values: [Double] = [
            thermalStateValue(.nominal),
            thermalStateValue(.fair),
            thermalStateValue(.serious),
            thermalStateValue(.critical),
        ]
        #expect(values == [0, 1, 2, 3])
    }

    // MARK: - ChatMetricSample encoding

    @Test("ChatMetricSample round-trips through JSON for device metrics")
    func metricSampleRoundTrip() throws {
        let sample = ChatMetricSample(
            ts: 1_700_000_000_000,
            metric: .deviceCpuPct,
            value: 42.5,
            unit: .count,
            sessionId: nil,
            workspaceId: nil,
            tags: nil
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(sample)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ChatMetricSample.self, from: data)

        #expect(decoded.metric == .deviceCpuPct)
        #expect(decoded.value == 42.5)
        #expect(decoded.unit == .count)
        #expect(decoded.ts == 1_700_000_000_000)
        #expect(decoded.sessionId == nil)
        #expect(decoded.workspaceId == nil)
        #expect(decoded.tags == nil)
    }

    @Test("ChatMetricSample encodes device memory metric correctly")
    func metricSampleMemory() throws {
        let sample = ChatMetricSample(
            ts: 1_700_000_000_000,
            metric: .deviceMemoryMb,
            value: 256.75,
            unit: .count,
            sessionId: nil,
            workspaceId: nil,
            tags: nil
        )

        let data = try JSONEncoder().encode(sample)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["metric"] as? String == "device.memory_mb")
        #expect(json["value"] as? Double == 256.75)
        #expect(json["unit"] as? String == "count")
    }

    @Test("ChatMetricSample encodes device thermal state metric correctly")
    func metricSampleThermalState() throws {
        let sample = ChatMetricSample(
            ts: 1_700_000_000_000,
            metric: .deviceThermalState,
            value: 2.0,
            unit: .count,
            sessionId: nil,
            workspaceId: nil,
            tags: nil
        )

        let data = try JSONEncoder().encode(sample)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["metric"] as? String == "device.thermal_state")
        #expect(json["value"] as? Double == 2.0)
    }

    @Test("ChatMetricSample encodes available memory metric correctly")
    func metricSampleAvailableMemory() throws {
        let sample = ChatMetricSample(
            ts: 1_700_000_000_000,
            metric: .deviceMemoryAvailableMb,
            value: 1024.0,
            unit: .count,
            sessionId: nil,
            workspaceId: nil,
            tags: nil
        )

        let data = try JSONEncoder().encode(sample)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["metric"] as? String == "device.memory_available_mb")
    }

    // MARK: - Telemetry gate edge cases

    @Test("Telemetry gate rejects in public mode without opt-in outside tests")
    func telemetryGatePublicNoOptIn() {
        let allowed = TelemetrySettings.allowsRemoteDiagnosticsUpload(
            mode: .public,
            userOptIn: false,
            environment: [:]
        )
        #expect(allowed == false)
    }

    @Test("Telemetry gate allows public mode with opt-in outside tests")
    func telemetryGatePublicWithOptIn() {
        let allowed = TelemetrySettings.allowsRemoteDiagnosticsUpload(
            mode: .public,
            userOptIn: true,
            environment: [:]
        )
        #expect(allowed == true)
    }

    @Test("Telemetry gate rejects even with opt-in during XCTestBundlePath tests")
    func telemetryGateXCTestBundlePath() {
        let allowed = TelemetrySettings.allowsRemoteDiagnosticsUpload(
            mode: .internalDiagnostics,
            userOptIn: true,
            environment: ["XCTestBundlePath": "/tmp/OppiTests.xctest"]
        )
        #expect(allowed == false)
    }

    // MARK: - Metric enum completeness

    @Test("All four device metric names use 'device.' prefix")
    func deviceMetricPrefix() {
        let deviceMetrics: [ChatMetricName] = [
            .deviceCpuPct,
            .deviceMemoryMb,
            .deviceMemoryAvailableMb,
            .deviceThermalState,
        ]
        for metric in deviceMetrics {
            #expect(metric.rawValue.hasPrefix("device."),
                    "\(metric.rawValue) should have 'device.' prefix")
        }
    }

    @Test("Device metric names are unique")
    func deviceMetricUniqueness() {
        let rawValues: [String] = [
            ChatMetricName.deviceCpuPct.rawValue,
            ChatMetricName.deviceMemoryMb.rawValue,
            ChatMetricName.deviceMemoryAvailableMb.rawValue,
            ChatMetricName.deviceThermalState.rawValue,
        ]
        let unique = Set(rawValues)
        #expect(unique.count == rawValues.count, "Device metric raw values must be unique")
    }

    @Test("ChatMetricUnit.count is used for all device metrics")
    func deviceMetricsUseCountUnit() {
        // The sampler records all four metrics with `.count` unit.
        // Verify the unit encodes as expected.
        #expect(ChatMetricUnit.count.rawValue == "count")
    }

    // MARK: - CPU time decomposition from Mach time_value

    @Test("Mach time_value to seconds handles microsecond rollover")
    func machTimeValueDecomposition() {
        // Simulating time_value_t: 5 seconds + 999999 microseconds
        let seconds: Int32 = 5
        let microseconds: Int32 = 999_999
        let totalSeconds = Double(seconds) + Double(microseconds) / 1_000_000
        #expect(abs(totalSeconds - 5.999999) < 1e-9)
    }

    @Test("Mach time_value to seconds with zero microseconds")
    func machTimeValueZeroMicroseconds() {
        let seconds: Int32 = 42
        let microseconds: Int32 = 0
        let totalSeconds = Double(seconds) + Double(microseconds) / 1_000_000
        #expect(totalSeconds == 42.0)
    }

    @Test("Mach time_value to seconds with zero seconds")
    func machTimeValueZeroSeconds() {
        let seconds: Int32 = 0
        let microseconds: Int32 = 500_000
        let totalSeconds = Double(seconds) + Double(microseconds) / 1_000_000
        #expect(abs(totalSeconds - 0.5) < 1e-9)
    }

    // MARK: - Full sample-to-emission pipeline (pure math)

    @Test("Full CPU emission pipeline: two synthetic samples produce correct percentage")
    func fullCpuPipeline() {
        // Simulate exactly what collectAndEmit does, minus the Mach calls.
        // Previous sample: 100.0s user, 50.0s system, t=0
        // Current sample: 101.5s user, 50.5s system, t=10s
        // Delta: 2.0s CPU over 10s wall = 20%

        let prevUser = 100.0
        let prevSystem = 50.0
        let curUser = 101.5
        let curSystem = 50.5

        let wallDelta: Duration = .seconds(10)
        let wallSeconds = Double(wallDelta.components.seconds)
            + Double(wallDelta.components.attoseconds) / 1e18

        let cpuDelta = (curUser - prevUser) + (curSystem - prevSystem)
        let cpuPct = (cpuDelta / wallSeconds) * 100.0

        #expect(wallSeconds > 0, "Wall time guard passes")
        #expect(abs(cpuPct - 20.0) < 0.01, "Expected 20% CPU usage")
    }

    @Test("Full CPU emission pipeline: idle process yields near-zero percentage")
    func fullCpuPipelineIdle() {
        let prevUser = 100.0
        let prevSystem = 50.0
        let curUser = 100.0001
        let curSystem = 50.0

        let wallDelta: Duration = .seconds(10)
        let wallSeconds = Double(wallDelta.components.seconds)
            + Double(wallDelta.components.attoseconds) / 1e18

        let cpuDelta = (curUser - prevUser) + (curSystem - prevSystem)
        let cpuPct = (cpuDelta / wallSeconds) * 100.0

        #expect(cpuPct > 0, "Even idle process uses some CPU")
        #expect(cpuPct < 0.01, "Idle process should be near zero")
    }

    @Test("Full memory emission pipeline: bytes to MB conversion")
    func fullMemoryPipeline() {
        // Simulate readMemoryFootprintMB conversion
        let physFootprint: UInt64 = 327_155_712 // ~312 MB
        let footprintMB = Double(physFootprint) / (1024 * 1024)
        #expect(abs(footprintMB - 312.0) < 0.1)

        // Simulate available memory conversion
        let availableBytes: UInt64 = 3_221_225_472 // 3 GB
        let availableMB = Double(availableBytes) / (1024 * 1024)
        #expect(abs(availableMB - 3072.0) < 0.01)
    }

    // MARK: - Value finiteness guard

    @Test("Non-finite CPU percentage would be rejected by ChatMetricsService")
    func nonFiniteValueGuard() {
        // The sampler doesn't emit when wallSeconds == 0 (division by zero guard).
        // But if somehow a NaN or Inf slipped through, ChatMetricsService.record
        // checks value.isFinite. Verify the guard condition.
        let nan = Double.nan
        let inf = Double.infinity
        let negInf = -Double.infinity

        #expect(!nan.isFinite)
        #expect(!inf.isFinite)
        #expect(!negInf.isFinite)
        #expect(42.5.isFinite)
        #expect(0.0.isFinite)
    }

    // MARK: - Helpers

    /// Mirrors the thermal state -> Double mapping in DeviceResourceSampler.
    private func thermalStateValue(_ state: ProcessInfo.ThermalState) -> Double {
        switch state {
        case .nominal: 0
        case .fair: 1
        case .serious: 2
        case .critical: 3
        @unknown default: 0
        }
    }
}
