import Foundation
import Testing
@testable import Oppi

@Suite("WorkspaceDetailWorkspaceResolver")
struct WorkspaceDetailWorkspaceResolverTests {
    @Test func resolvePrefersActiveServerSnapshot() {
        let stale = makeWorkspace(
            id: "w1",
            name: "Old Name",
            hostMount: "~/workspace/old",
            skills: ["fetch"],
            defaultModel: "anthropic/claude-sonnet-4-20250514"
        )

        let latest = makeWorkspace(
            id: "w1",
            name: "New Name",
            hostMount: "~/workspace/new",
            skills: ["fetch", "web-browser"],
            defaultModel: "openai/gpt-5"
        )

        let resolved = WorkspaceDetailWorkspaceResolver.resolve(
            fallback: stale,
            currentServerId: "srv-1",
            workspacesByServer: ["srv-1": [latest]]
        )

        #expect(resolved.name == "New Name")
        #expect(resolved.hostMount == "~/workspace/new")
        #expect(resolved.skills == ["fetch", "web-browser"])
        #expect(resolved.defaultModel == "openai/gpt-5")
    }

    @Test func resolveFallsBackWhenServerIsUnknown() {
        let stale = makeWorkspace(id: "w1", name: "Old Name")
        let latest = makeWorkspace(id: "w1", name: "New Name")

        let resolved = WorkspaceDetailWorkspaceResolver.resolve(
            fallback: stale,
            currentServerId: nil,
            workspacesByServer: ["srv-1": [latest]]
        )

        #expect(resolved == stale)
    }

    @Test func resolveFallsBackWhenWorkspaceNotFound() {
        let stale = makeWorkspace(id: "w1", name: "Old Name")
        let differentWorkspace = makeWorkspace(id: "w2", name: "Other Workspace")

        let resolved = WorkspaceDetailWorkspaceResolver.resolve(
            fallback: stale,
            currentServerId: "srv-1",
            workspacesByServer: ["srv-1": [differentWorkspace]]
        )

        #expect(resolved == stale)
    }

    @Test func resolveUsesOnlyActiveServerPartition() {
        let stale = makeWorkspace(id: "w1", name: "Old Name")
        let latestOnOtherServer = makeWorkspace(id: "w1", name: "New Name")

        let resolved = WorkspaceDetailWorkspaceResolver.resolve(
            fallback: stale,
            currentServerId: "srv-1",
            workspacesByServer: ["srv-2": [latestOnOtherServer]]
        )

        #expect(resolved == stale)
    }

    private func makeWorkspace(
        id: String,
        name: String,
        hostMount: String? = nil,
        skills: [String] = [],
        defaultModel: String? = nil
    ) -> Workspace {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        return Workspace(
            id: id,
            name: name,
            description: nil,
            icon: nil,
            skills: skills,
            systemPrompt: nil,
            hostMount: hostMount,
            memoryEnabled: nil,
            memoryNamespace: nil,
            extensions: nil,
            gitStatusEnabled: true,
            defaultModel: defaultModel,
            createdAt: now,
            updatedAt: now
        )
    }
}
