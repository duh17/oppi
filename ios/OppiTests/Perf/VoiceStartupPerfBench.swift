import Foundation
import Testing
@testable import Oppi

/// Micro-benchmarks for voice input startup orchestration overhead.
///
/// Measures the time VoiceInputManager spends on state management, route
/// resolution, telemetry recording, and session monitor setup — using mock
/// providers that complete instantly. This isolates OUR code's latency
/// from Apple's Speech framework.
///
/// Output format: `METRIC name=number` for autoresearch consumption.
@Suite("VoiceStartupPerfBench")
@MainActor
struct VoiceStartupPerfBench {

    // MARK: - Configuration

    private static let iterations = 40
    private static let warmupIterations = 5

    // MARK: - Timing

    private static func measureMedianUs(
        _ block: () -> Void
    ) -> Double {
        var timings: [UInt64] = []
        timings.reserveCapacity(iterations + warmupIterations)

        for i in 0 ..< (warmupIterations + iterations) {
            let start = DispatchTime.now().uptimeNanoseconds
            block()
            let end = DispatchTime.now().uptimeNanoseconds
            if i >= warmupIterations {
                timings.append(end &- start)
            }
        }

        timings.sort()
        let median = timings[timings.count / 2]
        return Double(median) / 1000.0
    }

    private static func measureMedianUsAsync(
        setup: @MainActor () async -> Void = {},
        _ block: @MainActor () async throws -> Void
    ) async -> Double {
        var timings: [UInt64] = []
        timings.reserveCapacity(iterations + warmupIterations)

        for i in 0 ..< (warmupIterations + iterations) {
            await setup()
            let start = DispatchTime.now().uptimeNanoseconds
            try! await block()
            let end = DispatchTime.now().uptimeNanoseconds
            if i >= warmupIterations {
                timings.append(end &- start)
            }
        }

        timings.sort()
        let median = timings[timings.count / 2]
        return Double(median) / 1000.0
    }

    // MARK: - Factory

    private static func makeManager(
        engine: VoiceInputManager.TranscriptionEngine = .classicDictation,
        mode: VoiceInputManager.EngineMode = .onDevice
    ) -> (VoiceInputManager, MockVoiceProvider) {
        let provider = MockVoiceProvider(
            id: engine == .classicDictation ? .appleClassicDictation : .appleModernSpeech,
            engine: engine
        )
        let registry = VoiceProviderRegistry(providers: [provider])
        let routeResolver = VoiceInputRouteResolver()
        let sessionMonitor = VoiceInputSessionMonitor()
        let systemAccess = MockVoiceInputSystemAccess()

        let manager = VoiceInputManager(
            providerRegistry: registry,
            routeResolver: routeResolver,
            sessionMonitor: sessionMonitor,
            systemAccess: systemAccess
        )
        manager.setEngineMode(mode)
        return (manager, provider)
    }

    // MARK: - Benchmarks

    /// Full startRecording → .recording with warm mock provider (on-device mode).
    /// This is the user-facing latency we want to minimize.
    /// Cancel happens in setup of next iteration, excluded from timing.
    @Test func startRecordingWarm() async throws {
        // Suppress telemetry test hook to avoid interference
        VoiceInputTelemetry._recordMetricForTesting = nil

        let (manager, _) = Self.makeManager()

        let us = await Self.measureMedianUsAsync(
            setup: {
                if manager.isRecording || manager.isPreparing {
                    await manager.cancelRecording()
                }
            },
            {
                try await manager.startRecording(keyboardLanguage: "en", source: "bench")
            }
        )
        // Clean up after last iteration
        if manager.isRecording { await manager.cancelRecording() }
        print("METRIC start_recording_us=\(Int(us))")
    }

    /// stopRecording / cancelRecording overhead (cleanup path).
    @Test func cancelRecordingOverhead() async throws {
        VoiceInputTelemetry._recordMetricForTesting = nil
        let (manager, _) = Self.makeManager()

        let us = await Self.measureMedianUsAsync(
            setup: {
                if !manager.isRecording {
                    try! await manager.startRecording(keyboardLanguage: "en", source: "bench")
                }
            },
            {
                await manager.cancelRecording()
            }
        )
        print("METRIC cancel_us=\(Int(us))")
    }

    /// Prewarm orchestration overhead with mock provider.
    @Test func prewarmOverhead() async throws {
        VoiceInputTelemetry._recordMetricForTesting = nil
        let (manager, _) = Self.makeManager()

        let us = await Self.measureMedianUsAsync {
            manager.invalidateAllCaches()
            await manager.prewarm(keyboardLanguage: "en", source: "bench")
        }
        print("METRIC prewarm_us=\(Int(us))")
    }

    /// Cost of 5 recordVoiceMetric calls (what happens during startup).
    @Test func telemetry5xRecord() async throws {
        let annotation = VoiceMetricAnnotation(
            engine: "dictation", locale: "en-US", source: "bench"
        )
        var captureCount = 0
        VoiceInputTelemetry._recordMetricForTesting = { _, _, _, _ in
            captureCount += 1
        }
        defer { VoiceInputTelemetry._recordMetricForTesting = nil }

        let us = Self.measureMedianUs {
            VoiceInputTelemetry.recordMetric(
                .voiceSetupMs, valueMs: 42, annotation: annotation,
                phase: .modelReady, status: "ok", extraTags: ["path": "warm_cache"]
            )
            VoiceInputTelemetry.recordMetric(
                .voiceSetupMs, valueMs: 5, annotation: annotation,
                phase: .transcriberCreate, status: "ok", extraTags: ["path": "warm_cache"]
            )
            VoiceInputTelemetry.recordMetric(
                .voiceSetupMs, valueMs: 12, annotation: annotation,
                phase: .analyzerStart, status: "ok", extraTags: ["path": "warm_cache"]
            )
            VoiceInputTelemetry.recordMetric(
                .voiceSetupMs, valueMs: 8, annotation: annotation,
                phase: .audioStart, status: "ok", extraTags: ["path": "warm_cache"]
            )
            VoiceInputTelemetry.recordMetric(
                .voiceSetupMs, valueMs: 67, annotation: annotation,
                phase: .total, status: "ok", extraTags: ["path": "warm_cache"]
            )
        }
        print("METRIC telemetry_5x_us=\(Int(us))")
    }

    /// Cost of building VoiceMetricAnnotation tags dictionary.
    @Test func tagsBuild() {
        let annotation = VoiceMetricAnnotation(
            engine: "dictation", locale: "en-US", source: "bench"
        )

        let us = Self.measureMedianUs {
            for _ in 0 ..< 5 {
                _ = annotation.tags(
                    phase: .modelReady,
                    status: "ok",
                    extra: ["path": "warm_cache"]
                )
            }
        }
        print("METRIC tags_build_5x_us=\(Int(us))")
    }

    /// Route resolution for on-device mode (no remote probe).
    @Test func routeResolveOnDevice() async {
        let resolver = VoiceInputRouteResolver()

        let us = await Self.measureMedianUsAsync {
            _ = await resolver.resolveEngine(
                mode: .onDevice,
                remoteEndpoint: nil,
                fallback: .classicDictation
            )
        }
        print("METRIC route_resolve_us=\(Int(us))")
    }

    /// Locale resolution + engine preference (sync path).
    @Test func localeResolve() {
        let us = Self.measureMedianUs {
            let locale = VoiceInputManager.resolvedLocale(keyboardLanguage: "en")
            _ = VoiceInputManager.preferredEngine(for: locale)
            _ = locale.identifier(.bcp47)
            _ = VoiceInputManager.languageLabel(for: locale)
        }
        print("METRIC locale_resolve_us=\(Int(us))")
    }

    /// ContinuousClock elapsed time computation.
    @Test func elapsedMsComputation() {
        let us = Self.measureMedianUs {
            for _ in 0 ..< 10 {
                let start = ContinuousClock.now
                let elapsed = ContinuousClock.now - start
                _ = Int(
                    elapsed.components.seconds * 1000
                        + elapsed.components.attoseconds / 1_000_000_000_000_000
                )
            }
        }
        print("METRIC elapsed_ms_10x_us=\(Int(us))")
    }

    /// SessionMonitor.bind() overhead (creates 2 Tasks).
    @Test func monitorBind() async {
        VoiceInputTelemetry._recordMetricForTesting = nil

        let us = await Self.measureMedianUsAsync {
            let monitor = VoiceInputSessionMonitor()
            let session = MockVoiceSession()
            monitor.bind(
                session: session,
                recordingStartTime: ContinuousClock.now,
                onAudioLevel: { _ in },
                onEvent: { _ in },
                onFirstTranscript: { _, _ in },
                onError: { _ in }
            )
            monitor.teardown()
        }
        print("METRIC monitor_bind_us=\(Int(us))")
    }

    /// ChatMetricSample construction cost (what ChatMetricsService.record does).
    @Test func sampleConstruction() {
        let tags: [String: String] = [
            "engine": "dictation",
            "locale": "en-US",
            "source": "bench",
            "phase": "model_ready",
            "status": "ok",
            "path": "warm_cache",
        ]

        let us = Self.measureMedianUs {
            for _ in 0 ..< 5 {
                _ = ChatMetricSample(
                    ts: ChatMetricsService.nowMs(),
                    metric: .voiceSetupMs,
                    value: 42.0,
                    unit: .ms,
                    sessionId: nil,
                    workspaceId: nil,
                    tags: tags
                )
            }
        }
        print("METRIC sample_construction_5x_us=\(Int(us))")
    }
}

// MARK: - Test Extension

extension VoiceInputManager {
    fileprivate func invalidateAllCaches() {
        _testModelReady = false
    }
}
