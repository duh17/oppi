import Testing
import Foundation
import SwiftUI
@testable import Oppi

// MARK: - Date+Relative

@Suite("Date+Relative")
struct DateRelativeTests {

    @Test func justNow() {
        let date = Date()
        #expect(date.relativeString() == "just now")
    }

    @Test func secondsAgo() {
        let date = Date().addingTimeInterval(-30)
        #expect(date.relativeString() == "just now")
    }

    @Test func oneMinuteAgo() {
        let date = Date().addingTimeInterval(-60)
        #expect(date.relativeString() == "1m ago")
    }

    @Test func multipleMinutesAgo() {
        let date = Date().addingTimeInterval(-1800) // 30 min
        #expect(date.relativeString() == "30m ago")
    }

    @Test func fiftyNineMinutesAgo() {
        let date = Date().addingTimeInterval(-3540) // 59 min
        #expect(date.relativeString() == "59m ago")
    }

    @Test func oneHourAgo() {
        let date = Date().addingTimeInterval(-3600)
        #expect(date.relativeString() == "1h ago")
    }

    @Test func multipleHoursAgo() {
        let date = Date().addingTimeInterval(-7200) // 2h
        #expect(date.relativeString() == "2h ago")
    }

    @Test func twentyThreeHoursAgo() {
        let date = Date().addingTimeInterval(-82800) // 23h
        #expect(date.relativeString() == "23h ago")
    }

    @Test func oneDayAgo() {
        let date = Date().addingTimeInterval(-86400)
        #expect(date.relativeString() == "1d ago")
    }

    @Test func multipleDaysAgo() {
        let date = Date().addingTimeInterval(-259200) // 3d
        #expect(date.relativeString() == "3d ago")
    }

    @Test func largeDaysValue() {
        let date = Date().addingTimeInterval(-2592000) // 30d
        #expect(date.relativeString() == "30d ago")
    }
}

// MARK: - String+Path

@Suite("String+Path")
struct StringPathTests {

    @Test func absoluteUserPath() {
        let path = "/Users/foo/workspace/project"
        #expect(path.shortenedPath == "~/workspace/project")
    }

    @Test func shortUserPath() {
        let path = "/Users/foo"
        // Only 2 parts after split — not enough to shorten
        #expect(path.shortenedPath == "/Users/foo")
    }

    @Test func nonUserPath() {
        let path = "/var/log/system.log"
        #expect(path.shortenedPath == "/var/log/system.log")
    }

    @Test func emptyString() {
        let path = ""
        #expect(path.shortenedPath == "")
    }

    @Test func deepNestedPath() {
        let path = "/Users/alice/a/b/c/d"
        #expect(path.shortenedPath == "~/a/b/c/d")
    }

    @Test func usersDirectoryOnly() {
        let path = "/Users/"
        // hasPrefix matches but split produces only ["Users"] which is < 3 parts
        #expect(path.shortenedPath == "/Users/")
    }

    @Test func relativePathPassthrough() {
        let path = "relative/path/file.txt"
        #expect(path.shortenedPath == "relative/path/file.txt")
    }
}

// MARK: - RiskLevel

@Suite("RiskLevel")
struct RiskLevelTests {

    @Test func allLabels() {
        #expect(RiskLevel.low.label == "Low")
        #expect(RiskLevel.medium.label == "Medium")
        #expect(RiskLevel.high.label == "High")
        #expect(RiskLevel.critical.label == "Critical")
    }

    @Test func allSystemImages() {
        #expect(RiskLevel.low.systemImage == "checkmark.shield")
        #expect(RiskLevel.medium.systemImage == "exclamationmark.shield")
        #expect(RiskLevel.high.systemImage == "exclamationmark.triangle")
        #expect(RiskLevel.critical.systemImage == "xmark.octagon")
    }

    @Test func riskColorReturnsDistinctColors() {
        let low = Color.riskColor(.low)
        let medium = Color.riskColor(.medium)
        let high = Color.riskColor(.high)
        let critical = Color.riskColor(.critical)

        // Each risk level should map to a distinct color
        #expect(low != medium)
        #expect(medium != high)
        #expect(high != critical)
        #expect(low != critical)
    }
}

// MARK: - SessionStatus+Color

@Suite("SessionStatus+Color")
struct SessionStatusColorTests {

    @Test func allStatusesHaveColors() {
        // Verify all cases produce a color without crashing
        let statuses: [SessionStatus] = [.starting, .ready, .busy, .stopping, .stopped, .error]
        for status in statuses {
            let color = status.color
            // Just verify it's a valid Color (not crashing is the test)
            #expect(color == color)
        }
    }

    @Test func distinctStatusColors() {
        #expect(SessionStatus.ready.color != SessionStatus.error.color)
        #expect(SessionStatus.busy.color != SessionStatus.stopping.color)
        #expect(SessionStatus.busy.color != SessionStatus.stopped.color)
        #expect(SessionStatus.starting.color != SessionStatus.ready.color)
    }
}
