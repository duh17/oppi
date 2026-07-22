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
            "warnings": ["Uses deprecated metadata"]
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
        #expect(detail.skillMarkdown == "# Release checklist")
        #expect(detail.files == ["SKILL.md", "references/checklist.md"])
    }

    @Test func decodesPathlessBuiltInOppiExtensionAndExactApprovalPolicies() throws {
        let catalog = try JSONDecoder().decode(ServerExtensionCatalog.self, from: Data("""
        {
          "extensions": [{
            "id": "oppi",
            "name": "Oppi",
            "description": "Server-owned controls.",
            "kind": "builtIn",
            "provenance": { "kind": "builtIn", "label": "Built-in extension" },
            "state": "off",
            "warnings": [],
            "isRemovable": false
          }],
          "oppiConfiguration": {
            "enabled": false,
            "approvalPolicy": "confirmDestructiveOnly",
            "revision": 0
          }
        }
        """.utf8))

        let oppi = try #require(catalog.extensions.first)
        #expect(oppi.id == "oppi")
        #expect(oppi.path == nil)
        #expect(oppi.packageName == nil)
        #expect(oppi.kind == .builtIn)
        #expect(oppi.provenance.kind == .builtIn)
        #expect(oppi.isRemovable == false)
        #expect(catalog.oppiConfiguration == OppiExtensionConfiguration(
            enabled: false,
            approvalPolicy: .confirmDestructiveOnly,
            revision: 0
        ))

        for rawPolicy in ["confirmDestructiveOnly", "confirmAllChanges", "readOnly"] {
            let policy = try JSONDecoder().decode(OppiApprovalPolicy.self, from: Data("\"\(rawPolicy)\"".utf8))
            #expect(policy.rawValue == rawPolicy)
        }
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
              "warnings": []
            },
            {
              "id": "skill_known",
              "name": "Known source",
              "description": "A Pi agent skill.",
              "provenance": { "kind": "piAgent", "label": "~/.pi/agent/skills" },
              "state": "enabled",
              "warnings": []
            }
          ]
        }
        """.utf8))

        #expect(catalog.skills.count == 2)
        #expect(catalog.skills[0].provenance.kind == .unknown)
        #expect(catalog.skills[1].provenance.kind == .piAgent)
    }

    @Test func preservesServerProvidedPackageNamesWhenDecodingAndEncodingCatalogEntries() throws {
        let skills = try JSONDecoder().decode(ServerSkillsCatalog.self, from: Data("""
        {"skills":[{"id":"skill_package","name":"Review tools","description":"Package skill.","provenance":{"kind":"package","label":"npm:@scope/review-tools@1.2.3"},"packageName":"@scope/review-tools","state":"enabled","warnings":[]}]}
        """.utf8))
        let extensions = try JSONDecoder().decode(ServerExtensionCatalog.self, from: Data("""
        {"extensions":[{"id":"extension_package","name":"Review extension","kind":"package","provenance":{"kind":"package","label":"npm:@scope/review-tools@1.2.3"},"packageName":"@scope/review-tools","state":"on","warnings":[],"isRemovable":false}],"oppiConfiguration":{"enabled":false,"approvalPolicy":"confirmDestructiveOnly","revision":0}}
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
    }
}
