import Testing
@testable import Oppi

@Suite("Mac path paint")
struct MacPathPaintTests {
    @Test func inspectorPathKeepsTheFilenameWhenTheDirectoryIsLong() {
        let path = "/Users/chenda/.config/oppi/worktrees/zs1JP9sA/wt_feat-mac-app-PRz1_RnV/clients/apple/OppiMac/Session/MacChatSessionRuntimeAdapter.swift"
        let painted = MacPathPaint.truncatedKeepingFileName(path, maxCharacters: 40)

        #expect(painted.hasSuffix("MacChatSessionRuntimeAdapter.swift"))
        #expect(painted.contains("…"))
        #expect(!painted.hasSuffix("ent.swift") || painted.hasSuffix("MacChatSessionRuntimeAdapter.swift"))
        #expect(painted != "/Users/ch...ent.swift")
        #expect(MacPathPaint.inspectorLabel(path) == "MacChatSessionRuntimeAdapter.swift")
    }

    @Test func shortPathsStayIntact() {
        #expect(MacPathPaint.truncatedKeepingFileName("README.md") == "README.md")
        #expect(
            MacPathPaint.truncatedKeepingFileName("clients/apple/OppiMac/Views/MacSessionShellViews.swift")
                .hasSuffix("MacSessionShellViews.swift")
        )
    }

    @Test func emptyAndFilenameOnlyPathsDoNotInventChrome() {
        #expect(MacPathPaint.truncatedKeepingFileName("") == "")
        #expect(MacPathPaint.truncatedKeepingFileName("MacChatSessionRuntimeAdapter.swift") == "MacChatSessionRuntimeAdapter.swift")
    }
}
