import Foundation
import Testing
@testable import Oppi

@Suite("Server resource models")
struct ServerResourceModelTests {
    @Test func decodesSeparateSkillSummaryAndDetail() throws {
        let detail = try JSONDecoder().decode(ServerSkillDetail.self, from: Data("""
        {
          "summary": {
            "id": "skill_9a4e",
            "name": "Release checklist",
            "description": "Review release readiness.",
            "provenance": { "kind": "piAgent", "label": "~/.pi/agent/skills" },
            "path": "/Users/test/.pi/agent/skills/release/SKILL.md",
            "state": "error",
            "loadError": "description is required",
            "warnings": ["Uses deprecated metadata"],
            "editable": true
          },
          "skillMarkdown": "# Release checklist",
          "files": ["SKILL.md", "references/checklist.md"]
        }
        """.utf8))

        #expect(detail.summary.id == "skill_9a4e")
        #expect(detail.summary.provenance.kind == .piAgent)
        #expect(detail.summary.state == .error)
        #expect(detail.summary.packageName == nil)
        #expect(detail.summary.loadError == "description is required")
        #expect(detail.summary.editable)
        #expect(detail.skillMarkdown == "# Release checklist")
        #expect(detail.files == ["SKILL.md", "references/checklist.md"])
    }

    @Test func unknownProvenanceDoesNotDiscardTheRestOfTheCatalog() throws {
        let catalog = try JSONDecoder().decode(ServerSkillsCatalog.self, from: Data("""
        {
          "skills": [
            {
              "id": "skill_future",
              "name": "Future source",
              "description": "A future Pi source.",
              "provenance": { "kind": "futureSource", "label": "Future source" },
              "state": "disabled",
              "warnings": [],
              "editable": false
            },
            {
              "id": "skill_known",
              "name": "Known source",
              "description": "A Pi agent skill.",
              "provenance": { "kind": "piAgent", "label": "~/.pi/agent/skills" },
              "state": "enabled",
              "warnings": [],
              "editable": true
            }
          ]
        }
        """.utf8))

        #expect(catalog.skills.count == 2)
        #expect(catalog.skills[0].provenance.kind == .unknown)
        #expect(catalog.skills[0].editable == false)
        #expect(catalog.skills[1].provenance.kind == .piAgent)
        #expect(catalog.skills[1].editable)
    }

    @Test func preservesServerProvidedPackageNamesWhenDecodingAndEncodingCatalogEntries() throws {
        let skills = try JSONDecoder().decode(ServerSkillsCatalog.self, from: Data("""
        {"skills":[{"id":"skill_package","name":"Review tools","description":"Package skill.","provenance":{"kind":"package","label":"npm:@scope/review-tools@1.2.3"},"packageName":"@scope/review-tools","state":"enabled","warnings":[],"editable":false}]}
        """.utf8))
        let extensions = try JSONDecoder().decode(ServerExtensionCatalog.self, from: Data("""
        {"extensions":[{"id":"extension_package","name":"Review extension","kind":"package","provenance":{"kind":"package","label":"npm:@scope/review-tools@1.2.3"},"packageName":"@scope/review-tools","state":"on","warnings":[],"isRemovable":false}],"builtInTools":[]}
        """.utf8))

        let skill = try #require(skills.skills.first)
        let serverExtension = try #require(extensions.extensions.first)
        let skillObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(skill))
        let extensionObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(serverExtension))
        let skillJSON = try #require(skillObject as? [String: Any])
        let extensionJSON = try #require(extensionObject as? [String: Any])

        #expect(skillJSON["packageName"] as? String == "@scope/review-tools")
        #expect(extensionJSON["packageName"] as? String == "@scope/review-tools")
    }

    @Test func decodesExtensionDetailWithContributionsAndErrorState() throws {
        let detail = try JSONDecoder().decode(ServerExtensionDetail.self, from: Data("""
        {
          "summary": {
            "id": "extension_8b0f",
            "name": "Review helpers",
            "description": null,
            "kind": "package",
            "provenance": { "kind": "package", "label": "Configured package source" },
            "state": "error",
            "loadError": "Failed to load extension",
            "warnings": ["Command name collides"],
            "isRemovable": false
          },
          "contributedTools": ["review"],
          "contributedCommands": ["/review"]
        }
        """.utf8))

        #expect(detail.summary.kind == .package)
        #expect(detail.summary.provenance.label == "Configured package source")
        #expect(detail.summary.path == nil)
        #expect(detail.summary.state == .error)
        #expect(detail.contributedTools == ["review"])
        #expect(detail.contributedCommands == ["/review"])
        // A server that predates plugins sends no plugin fields.
        #expect(detail.summary.kinds == nil)
        #expect(detail.summary.source == nil)
        #expect(detail.summary.plugin == nil)
    }

    @Test func decodesPluginRowsWithKindsSourceAndContributions() throws {
        let catalog = try JSONDecoder().decode(ServerExtensionCatalog.self, from: Data("""
        {
          "extensions": [
            {
              "id": "extension_durable",
              "name": "durable-only",
              "kind": "directory",
              "provenance": { "kind": "piAgent", "label": "~/.pi/agent/plugins" },
              "state": "on",
              "warnings": [],
              "isRemovable": false,
              "kinds": ["plugin"],
              "source": "owner",
              "plugin": {
                "extension": "durable-only",
                "required": false,
                "enabled": true,
                "runtimes": ["host", "sandbox"],
                "tools": ["durable_only_tool"],
                "hooks": [{ "task": "pi.generation", "handlers": ["beforeRequest", "beforeProviderRequest"] }],
                "sections": ["durable_only"],
                "wraps": [{ "tool": "read" }, { "section": "skills" }],
                "tasks": ["durable.task"],
                "kept": false
              }
            },
            {
              "id": "extension_both",
              "name": "webtools",
              "kind": "package",
              "provenance": { "kind": "package", "label": "npm:webtools" },
              "state": "error",
              "loadError": "Unexpected end of input",
              "warnings": [],
              "isRemovable": false,
              "kinds": ["plugin", "pi-extension"],
              "source": "owner",
              "plugin": {
                "extension": "webtools",
                "required": false,
                "enabled": true,
                "runtimes": ["host"],
                "tools": ["web_fetch"],
                "hooks": [],
                "sections": [],
                "wraps": [],
                "tasks": [],
                "loadError": "Unexpected end of input",
                "kept": true
              }
            },
            {
              "id": "extension_future",
              "name": "future",
              "kind": "builtIn",
              "provenance": { "kind": "builtIn", "label": "Oppi" },
              "state": "on",
              "warnings": [],
              "isRemovable": false,
              "kinds": ["plugin", "widget"],
              "source": "marketplace",
              "plugin": {
                "required": true,
                "enabled": true,
                "runtimes": ["host"],
                "tools": [],
                "hooks": [],
                "sections": [],
                "wraps": [{ "document": "future" }],
                "tasks": [],
                "kept": false
              }
            }
          ],
          "builtInTools": []
        }
        """.utf8))

        let durable = try #require(catalog.extensions.first)
        #expect(durable.kinds == [.plugin])
        #expect(durable.source == .owner)
        let plugin = try #require(durable.plugin)
        #expect(plugin.extensionName == "durable-only")
        #expect(!plugin.required)
        #expect(plugin.enabled)
        #expect(plugin.runtimes == ["host", "sandbox"])
        #expect(plugin.tools == ["durable_only_tool"])
        #expect(plugin.hooks == [
            ServerPluginHook(task: "pi.generation", handlers: ["beforeRequest", "beforeProviderRequest"]),
        ])
        #expect(plugin.sections == ["durable_only"])
        #expect(plugin.wraps == [ServerPluginWrap(tool: "read"), ServerPluginWrap(section: "skills")])
        #expect(plugin.tasks == ["durable.task"])
        #expect(plugin.loadError == nil)
        #expect(!plugin.kept)

        let both = catalog.extensions[1]
        #expect(both.kinds == [.plugin, .piExtension])
        #expect(both.state == .error)
        #expect(both.plugin?.loadError == "Unexpected end of input")
        #expect(both.plugin?.kept == true)

        // Values a later server adds decode as unknown instead of failing the catalog.
        let future = catalog.extensions[2]
        #expect(future.kinds == [.plugin, .unknown])
        #expect(future.source == .unknown)
        #expect(future.plugin?.required == true)
        #expect(future.plugin?.extensionName == nil)
        #expect(future.plugin?.wraps == [ServerPluginWrap()])
    }

    @Test func decodesAPluginReloadReport() throws {
        let report = try JSONDecoder().decode(ServerPluginReloadReport.self, from: Data("""
        {
          "loaded": [{ "name": "probe", "entry": "/p/probe/server.ts", "runtimes": ["host"], "tools": ["probe_version"], "builtIn": false, "required": false }],
          "kept": [{ "name": "webtools", "entry": "/p/webtools/server.ts", "runtimes": ["host"], "tools": [], "builtIn": false, "required": false }],
          "removed": ["gone"],
          "skipped": [{ "entry": "/p/ask", "message": "\\"ask\\" is built into Oppi", "plugin": "ask" }],
          "errors": [{ "entry": "/p/webtools/server.ts", "message": "Unexpected end of input", "plugin": "webtools" }, { "entry": "/p/broken", "message": "Invalid package.json" }]
        }
        """.utf8))

        #expect(report.loaded.map(\.name) == ["probe"])
        #expect(report.kept.map(\.name) == ["webtools"])
        #expect(report.removed == ["gone"])
        #expect(report.skipped.first?.plugin == "ask")
        #expect(report.errors.map(\.plugin) == ["webtools", nil])
    }

    @Test func decodesPiSystemPromptAndNullableDefaultTools() throws {
        let filePrompt = try JSONDecoder().decode(PiSystemPromptSnapshot.self, from: Data("""
        {"source":"file","path":"~/.pi/agent/SYSTEM.md","resolvedPath":"/tmp/SYSTEM.md","content":"# Live"}
        """.utf8))
        let defaultPrompt = try JSONDecoder().decode(PiSystemPromptSnapshot.self, from: Data("""
        {"source":"default","path":"~/.pi/agent/SYSTEM.md","content":"You are an expert coding assistant operating inside pi"}
        """.utf8))
        let inherited = try JSONDecoder().decode(PiDefaultToolsSnapshot.self, from: Data(#"{"defaultTools":null}"#.utf8))
        let exact = try JSONDecoder().decode(PiDefaultToolsSnapshot.self, from: Data(#"{"defaultTools":[]}"#.utf8))

        #expect(filePrompt.source == .file)
        #expect(filePrompt.resolvedPath == "/tmp/SYSTEM.md")
        #expect(defaultPrompt.source == .default)
        #expect(inherited.defaultTools == nil)
        #expect(exact.defaultTools?.isEmpty == true)
    }
}
