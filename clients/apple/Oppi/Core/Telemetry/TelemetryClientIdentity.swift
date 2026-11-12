import Foundation

/// The `client` envelope every telemetry upload (events, client logs, MetricKit)
/// carries. Built once per process; nothing in it changes while the app runs.
enum TelemetryClientIdentity {
    static let current = TelemetryClientInfo(
        kind: PlatformCapabilities.reportsAsMac ? .mac : .ios,
        appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
        buildNumber: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
        gitCommit: AppBuildIdentity.gitCommit,
        osVersion: osVersion(ProcessInfo.processInfo.operatingSystemVersion),
        deviceModel: hardwareIdentifier(),
        appInstanceId: ClientLogUploadService.appInstanceId,
        bootId: ClientLogUploadService.bootId
    )

    /// `26.1` or `26.1.2`; the patch level appears only when it is not zero.
    static func osVersion(_ version: OperatingSystemVersion) -> String {
        let base = "\(version.majorVersion).\(version.minorVersion)"
        return version.patchVersion == 0 ? base : "\(base).\(version.patchVersion)"
    }

    /// The hardware identifier (`iPhone17,1`, `Mac16,10`), not the marketing
    /// family. The simulator reports its host CPU, so it uses the device it
    /// emulates.
    private static func hardwareIdentifier() -> String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"], !simulated.isEmpty {
            return simulated
        }
        let key = PlatformCapabilities.reportsAsMac ? "hw.model" : "hw.machine"
        var size = 0
        sysctlbyname(key, nil, &size, nil, 0)
        guard size > 1 else { return "unknown" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(key, &buffer, &size, nil, 0) == 0 else { return "unknown" }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
