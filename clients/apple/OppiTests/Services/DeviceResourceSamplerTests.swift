import Darwin
import Foundation
import Testing
@testable import Oppi

@Suite("DeviceResourceSampler")
struct DeviceResourceSamplerTests {

    /// The sampler once read `mach_task_basic_info`, which counts only exited
    /// threads: a fully busy main thread reported 0% CPU.
    @Test("Process CPU time includes a busy live thread")
    func processCPUIncludesLiveThread() throws {
        let processBefore = try #require(DeviceResourceSampler.processCPUSeconds())
        let threadStart = Self.threadCPUSeconds()
        let deadline = Date().addingTimeInterval(10)
        var sink = 0.0
        while Self.threadCPUSeconds() - threadStart < 0.1, Date() < deadline {
            sink += sin(sink) + 1
        }
        let burned = Self.threadCPUSeconds() - threadStart
        let processAfter = try #require(DeviceResourceSampler.processCPUSeconds())

        #expect(burned >= 0.1)
        // The process total includes this thread; allow timer granularity.
        #expect(processAfter - processBefore >= burned - 0.01)
        #expect(sink.isFinite)
    }

    @Test("Thermal state maps to its 0-3 severity")
    func thermalStateSeverity() {
        #expect(DeviceResourceSampler.thermalStateValue(.nominal) == 0)
        #expect(DeviceResourceSampler.thermalStateValue(.fair) == 1)
        #expect(DeviceResourceSampler.thermalStateValue(.serious) == 2)
        #expect(DeviceResourceSampler.thermalStateValue(.critical) == 3)
    }

    private static func threadCPUSeconds() -> Double {
        Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1_000_000_000
    }
}
