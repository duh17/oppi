import Testing
import UIKit
@testable import Oppi

@Suite("USDZInspectPose")
struct USDZInspectPoseTests {
    @Test func orbitTurnsWithTheFingerAndStopsAtThePitchLimit() {
        var pose = USDZInspectPose()
        pose.orbit(by: CGPoint(x: 100, y: -50))
        #expect(abs(pose.yaw - 1) < 1e-5)
        #expect(abs(pose.pitch - 0.5) < 1e-5)

        pose.orbit(by: CGPoint(x: 0, y: -10_000))
        #expect(pose.pitch == USDZInspectPose.maximumPitch)
        pose.orbit(by: CGPoint(x: 0, y: 100_000))
        #expect(pose.pitch == -USDZInspectPose.maximumPitch)
    }

    @Test func pinchScalesFromWhereItBeganWithinTheZoomRange() {
        var pose = USDZInspectPose()
        pose.zoom(from: 1, scale: 2)
        #expect(pose.zoom == 2)
        // A continuing pinch is measured from its start, not compounded.
        pose.zoom(from: 1, scale: 2)
        #expect(pose.zoom == 2)

        pose.zoom(from: 2, scale: 100)
        #expect(pose.zoom == USDZInspectPose.zoomRange.upperBound)
        pose.zoom(from: 1, scale: 0.001)
        #expect(pose.zoom == USDZInspectPose.zoomRange.lowerBound)
    }

    @Test func twoFingerPanFlipsScreenYAndIsBounded() {
        var pose = USDZInspectPose()
        pose.pan(by: CGPoint(x: 250, y: 250))
        #expect(abs(pose.pan.x - 1) < 1e-5)
        #expect(abs(pose.pan.y + 1) < 1e-5)

        pose.pan(by: CGPoint(x: 1_000_000, y: -1_000_000))
        #expect(pose.pan == SIMD2(USDZInspectPose.maximumPan, USDZInspectPose.maximumPan))
    }
}
