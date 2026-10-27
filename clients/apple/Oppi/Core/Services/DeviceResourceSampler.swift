import Darwin
import Foundation
import os
import UIKit

private let samplerLog = Logger(subsystem: AppIdentifiers.subsystem, category: "DeviceResourceSampler")

/// Samples CPU, memory, and thermal metrics every 10 seconds while the app is
/// foregrounded. All sampling and uploads are gated by `TelemetrySettings`.
///
/// One `app.device_resources` event per tick carries the app state at sample
/// time (`screen`, `stream_state`, `agents`, `voice`) from `TelemetryContext`,
/// so a spike can be traced to what was on screen.
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
        let cpuSeconds: Double
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

        let context = TelemetryContext.current()

        // CPU needs a delta from the previous sample; the first tick after a
        // resume has none and reports no CPU.
        let currentCPU = readCPUSample()
        var cpuPct: Double?
        if let prev = previousCPUSample, let cur = currentCPU {
            let wallDelta = prev.timestamp.duration(to: cur.timestamp)
            let wallSeconds = Double(wallDelta.components.seconds)
                + Double(wallDelta.components.attoseconds) / 1e18
            if wallSeconds > 0 {
                cpuPct = ((cur.cpuSeconds - prev.cpuSeconds) / wallSeconds) * 100.0
            }
        }
        previousCPUSample = currentCPU

        Telemetry.record(
            AppDeviceResources(
                cpuPct: cpuPct,
                memoryMb: readMemoryFootprintMB(),
                memoryAvailableMb: Double(os_proc_available_memory()) / (1024 * 1024),
                thermalState: Self.thermalStateValue(ProcessInfo.processInfo.thermalState),
                screen: context.screen,
                streamState: context.streamState,
                agents: context.agents,
                voice: context.voice
            )
        )
    }

    /// 0 nominal, 1 fair, 2 serious, 3 critical.
    nonisolated static func thermalStateValue(_ state: ProcessInfo.ThermalState) -> Int {
        switch state {
        case .nominal: 0
        case .fair: 1
        case .serious: 2
        case .critical: 3
        @unknown default: 0
        }
    }

    // MARK: - System API helpers

    private func readCPUSample() -> CPUSample? {
        guard let cpuSeconds = Self.processCPUSeconds() else { return nil }
        return CPUSample(timestamp: .now, cpuSeconds: cpuSeconds)
    }

    /// User plus system CPU time of every thread in the process, live or exited.
    /// `mach_task_basic_info` reports only exited threads, which left the main
    /// thread out entirely.
    nonisolated static func processCPUSeconds() -> Double? {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    private nonisolated static func seconds(_ time: timeval) -> Double {
        Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000
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
