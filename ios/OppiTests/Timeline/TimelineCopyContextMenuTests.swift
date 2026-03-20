import Foundation
import Testing
import UIKit
@testable import Oppi

@Suite("Timeline copy context menus")
struct TimelineCopyContextMenuTests {
    @MainActor
    @Test(arguments: TimelineCopyRowCase.allCases)
    func rowContextMenuUsesCopyPrimary(_ rowCase: TimelineCopyRowCase) throws {
        let menu = try #require(rowCase.makeContextMenu())
        #expect(timelineActionTitles(in: menu) == ["Copy"])
    }

    @MainActor
    @Test(arguments: TimelineCopyRowCase.allCases)
    func rowInstallsDoubleTapCopyGesture(_ rowCase: TimelineCopyRowCase) {
        assertHasDoubleTapGesture(in: rowCase.makeView())
    }

    @MainActor
    @Test(arguments: TimelineCopyRowCase.allCases)
    func rowReconfigurationKeepsSingleDoubleTapGesture(_ rowCase: TimelineCopyRowCase) throws {
        let view = rowCase.makeView()

        rowCase.reconfigure(view)
        rowCase.reconfigure(view)

        let doubleTapCount = timelineAllGestureRecognizers(in: view).reduce(into: 0) { count, recognizer in
            guard let tap = recognizer as? UITapGestureRecognizer,
                  tap.numberOfTapsRequired == 2 else { return }
            count += 1
        }

        #expect(doubleTapCount == 1, "Expected exactly one double-tap recognizer for \(rowCase.name)")

        let menu = try #require(rowCase.contextMenu(from: view))
        #expect(timelineActionTitles(in: menu) == ["Copy"])
    }
}

enum TimelineCopyRowCase: CaseIterable, Sendable {
    case user
    case permission
    case error
    case compaction

    var name: String {
        switch self {
        case .user: return "user"
        case .permission: return "permission"
        case .error: return "error"
        case .compaction: return "compaction"
        }
    }

    @MainActor
    func makeContextMenu() -> UIMenu? {
        contextMenu(from: makeView())
    }

    @MainActor
    func makeView() -> UIView {
        switch self {
        case .user:
            return UserTimelineRowContentView(configuration: userConfiguration)
        case .permission:
            return PermissionTimelineRowContentView(configuration: permissionConfiguration)
        case .error:
            return ErrorTimelineRowContentView(configuration: errorConfiguration)
        case .compaction:
            return CompactionTimelineRowContentView(configuration: compactionConfiguration)
        }
    }

    @MainActor
    func reconfigure(_ view: UIView) {
        switch self {
        case .user:
            guard let typedView = view as? UserTimelineRowContentView else {
                Issue.record("Expected UserTimelineRowContentView for \(name)")
                return
            }
            typedView.configuration = userConfiguration

        case .permission:
            guard let typedView = view as? PermissionTimelineRowContentView else {
                Issue.record("Expected PermissionTimelineRowContentView for \(name)")
                return
            }
            typedView.configuration = permissionConfiguration

        case .error:
            guard let typedView = view as? ErrorTimelineRowContentView else {
                Issue.record("Expected ErrorTimelineRowContentView for \(name)")
                return
            }
            typedView.configuration = errorConfiguration

        case .compaction:
            guard let typedView = view as? CompactionTimelineRowContentView else {
                Issue.record("Expected CompactionTimelineRowContentView for \(name)")
                return
            }
            typedView.configuration = compactionConfiguration
        }
    }

    @MainActor
    func contextMenu(from view: UIView) -> UIMenu? {
        switch self {
        case .user:
            return (view as? UserTimelineRowContentView)?.contextMenu()
        case .permission:
            return (view as? PermissionTimelineRowContentView)?.contextMenu()
        case .error:
            return (view as? ErrorTimelineRowContentView)?.contextMenu()
        case .compaction:
            return (view as? CompactionTimelineRowContentView)?.contextMenu()
        }
    }

    private var userConfiguration: UserTimelineRowConfiguration {
        UserTimelineRowConfiguration(
            text: "hello",
            images: [],
            canFork: false,
            onFork: nil,
            themeID: .dark
        )
    }

    private var permissionConfiguration: PermissionTimelineRowConfiguration {
        PermissionTimelineRowConfiguration(
            outcome: .allowed,
            tool: "bash",
            summary: "command: ls",
            themeID: .dark
        )
    }

    private var errorConfiguration: ErrorTimelineRowConfiguration {
        ErrorTimelineRowConfiguration(
            message: "Permission denied",
            themeID: .dark
        )
    }

    private var compactionConfiguration: CompactionTimelineRowConfiguration {
        CompactionTimelineRowConfiguration(
            presentation: .init(
                phase: .completed,
                detail: "Summary",
                tokensBefore: 12_345
            ),
            isExpanded: false,
            themeID: .dark
        )
    }
}
