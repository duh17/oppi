import Darwin
import Foundation
import os
import UIKit

private let samplerLog = Logger(subsystem: AppIdentifiers.subsystem, category: "DeviceResourceSampler")

/// Samples CPU, memory, and thermal metrics every 10 seconds while the app is
/// foregrounded. All sampling and uploads are gated by `TelemetrySettings`.
@MainActor
final class DeviceResourceSampler {
    static let shared = DeviceResourceSampler()

    // MARK: - Configuration

    private static let sampleInterval: Duration = .seconds(10)

    // MARK: - State

    private var samplingTask: Task<Void, Never>?
    private var previousCPUSample: CPUSample?
    private var configured = false

    private struct CPUSample {
        let timestamp: ContinuousClock.Instant
        let userSeconds: Double
        let systemSeconds: Double
    }

    private init() {}

    // MARK: - Lifecycle

    /// Call once from `OppiApp.init` alongside `MetricKitService.shared.configure()`.
    func configure() {
        guard !configured else { return }
        configured = true

        let nc = NotificationCenter.default
        nc.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        nc.addObserver(
            self,
            selector: #selector(appWillResignActive),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )

        startIfAllowed()
    }

    /// Called when the user toggles diagnostics in Settings.
    func refreshAfterPreferenceChange() {
        if TelemetrySettings.allowsRemoteDiagnosticsUpload {
            startIfAllowed()
        } else {
            stopSampling()
        }
    }

    // MARK: - Notifications

    @objc private func appDidBecomeActive() {
        startIfAllowed()
    }

    @objc private func appWillResignActive() {
        stopSampling()
    }

    // MARK: - Timer

    private func startIfAllowed() {
        guard TelemetrySettings.allowsRemoteDiagnosticsUpload else { return }
        guard samplingTask == nil else { return }

        // Seed the CPU baseline so the first real sample has a valid delta.
        previousCPUSample = readCPUSample()

        samplingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.sampleInterval)
                guard !Task.isCancelled else { break }
                await self?.collectAndEmit()
            }
        }
        samplerLog.info("Device resource sampling started")
    }

    private func stopSampling() {
        samplingTask?.cancel()
        samplingTask = nil
        previousCPUSample = nil
        samplerLog.info("Device resource sampling stopped")
    }

    // MARK: - Sample collection

    private func collectAndEmit() async {
        guard TelemetrySettings.allowsRemoteDiagnosticsUpload else {
            stopSampling()
            return
        }

        // CPU (needs delta from previous sample)
        let currentCPU = readCPUSample()
        if let prev = previousCPUSample, let cur = currentCPU {
            let wallDelta = prev.timestamp.duration(to: cur.timestamp)
            let wallSeconds = Double(wallDelta.components.seconds)
                + Double(wallDelta.components.attoseconds) / 1e18
            if wallSeconds > 0 {
                let cpuDelta = (cur.userSeconds - prev.userSeconds)
                    + (cur.systemSeconds - prev.systemSeconds)
                let cpuPct = (cpuDelta / wallSeconds) * 100.0
                await ChatMetricsService.shared.record(
                    metric: .deviceCpuPct,
                    value: cpuPct,
                    unit: .count
                )
            }
        }
        previousCPUSample = currentCPU

        // Memory footprint
        if let footprintMB = readMemoryFootprintMB() {
            await ChatMetricsService.shared.record(
                metric: .deviceMemoryMb,
                value: footprintMB,
                unit: .count
            )
        }

        // Available memory (headroom before jetsam)
        let availableMB = Double(os_proc_available_memory()) / (1024 * 1024)
        await ChatMetricsService.shared.record(
            metric: .deviceMemoryAvailableMb,
            value: availableMB,
            unit: .count
        )

        // Thermal state
        let thermalValue: Double = switch ProcessInfo.processInfo.thermalState {
        case .nominal: 0
        case .fair: 1
        case .serious: 2
        case .critical: 3
        @unknown default: 0
        }
        await ChatMetricsService.shared.record(
            metric: .deviceThermalState,
            value: thermalValue,
            unit: .count
        )
    }

    // MARK: - Mach API helpers

    private func readCPUSample() -> CPUSample? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let userSec = Double(info.user_time.seconds)
            + Double(info.user_time.microseconds) / 1_000_000
        let sysSec = Double(info.system_time.seconds)
            + Double(info.system_time.microseconds) / 1_000_000

        return CPUSample(
            timestamp: .now,
            userSeconds: userSec,
            systemSeconds: sysSec
        )
    }

    private func readMemoryFootprintMB() -> Double? {
        var vmInfo = task_vm_info()
        var vmCount = mach_msg_type_number_t(
            MemoryLayout<task_vm_info>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &vmInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &vmCount)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Double(vmInfo.phys_footprint) / (1024 * 1024)
    }
}
