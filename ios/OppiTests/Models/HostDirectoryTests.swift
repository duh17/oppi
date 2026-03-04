import Testing
import Foundation
@testable import Oppi

@Suite("HostDirectory decoding + computed properties")
struct HostDirectoryTests {

    // MARK: - JSON Decoding

    @Test func decodesFullPayload() throws {
        let json = """
        {
            "path": "~/workspace/oppi",
            "name": "oppi",
            "isGitRepo": true,
            "gitRemote": "github.com/duh17/oppi",
            "hasAgentsMd": true,
            "projectType": "node",
            "language": "TypeScript"
        }
        """.data(using: .utf8)!

        let dir = try JSONDecoder().decode(HostDirectory.self, from: json)
        #expect(dir.path == "~/workspace/oppi")
        #expect(dir.name == "oppi")
        #expect(dir.isGitRepo == true)
        #expect(dir.gitRemote == "github.com/duh17/oppi")
        #expect(dir.hasAgentsMd == true)
        #expect(dir.projectType == "node")
        #expect(dir.language == "TypeScript")
    }

    @Test func decodesMinimalPayload() throws {
        let json = """
        {
            "path": "~/src/experiment",
            "name": "experiment",
            "isGitRepo": false,
            "hasAgentsMd": false
        }
        """.data(using: .utf8)!

        let dir = try JSONDecoder().decode(HostDirectory.self, from: json)
        #expect(dir.path == "~/src/experiment")
        #expect(dir.name == "experiment")
        #expect(dir.isGitRepo == false)
        #expect(dir.gitRemote == nil)
        #expect(dir.hasAgentsMd == false)
        #expect(dir.projectType == nil)
        #expect(dir.language == nil)
    }

    @Test func decodesDirectoriesArrayResponse() throws {
        let json = """
        {
            "directories": [
                {
                    "path": "~/workspace/oppi",
                    "name": "oppi",
                    "isGitRepo": true,
                    "hasAgentsMd": true,
                    "projectType": "node",
                    "language": "TypeScript"
                },
                {
                    "path": "~/workspace/kypu",
                    "name": "kypu",
                    "isGitRepo": true,
                    "hasAgentsMd": false,
                    "projectType": "go",
                    "language": "Go"
                }
            ]
        }
        """.data(using: .utf8)!

        struct Response: Decodable { let directories: [HostDirectory] }
        let response = try JSONDecoder().decode(Response.self, from: json)
        #expect(response.directories.count == 2)
        #expect(response.directories[0].name == "oppi")
        #expect(response.directories[1].name == "kypu")
    }

    // MARK: - Identifiable

    @Test func idIsPath() {
        let dir = makeDirectory(path: "~/workspace/test", name: "test")
        #expect(dir.id == "~/workspace/test")
    }

    // MARK: - projectTypeIcon

    @Test func iconForKnownProjectTypes() {
        #expect(makeDirectory(projectType: "node").projectTypeIcon == "n.square")
        #expect(makeDirectory(projectType: "swift").projectTypeIcon == "swift")
        #expect(makeDirectory(projectType: "xcodegen").projectTypeIcon == "swift")
        #expect(makeDirectory(projectType: "go").projectTypeIcon == "g.square")
        #expect(makeDirectory(projectType: "rust").projectTypeIcon == "r.square")
        #expect(makeDirectory(projectType: "python").projectTypeIcon == "p.square")
        #expect(makeDirectory(projectType: "ruby").projectTypeIcon == "r.square")
        #expect(makeDirectory(projectType: "gradle").projectTypeIcon == "j.square")
        #expect(makeDirectory(projectType: "maven").projectTypeIcon == "j.square")
        #expect(makeDirectory(projectType: "elixir").projectTypeIcon == "e.square")
        #expect(makeDirectory(projectType: "make").projectTypeIcon == "m.square")
    }

    @Test func iconForUnknownProjectType() {
        #expect(makeDirectory(projectType: nil).projectTypeIcon == "folder")
        #expect(makeDirectory(projectType: "unknown").projectTypeIcon == "folder")
    }

    // MARK: - CreateWorkspaceRequest encoding

    @Test func createRequestIncludesGitStatusEnabled() throws {
        let request = CreateWorkspaceRequest(
            name: "oppi",
            skills: ["search", "fetch"],
            hostMount: "~/workspace/oppi",
            gitStatusEnabled: true,
            memoryEnabled: true
        )

        let data = try JSONEncoder().encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        #expect(json["name"] as? String == "oppi")
        #expect(json["hostMount"] as? String == "~/workspace/oppi")
        #expect(json["gitStatusEnabled"] as? Bool == true)
        #expect(json["memoryEnabled"] as? Bool == true)
        #expect((json["skills"] as? [String])?.count == 2)
    }

    @Test func createRequestOmitsNilFields() throws {
        let request = CreateWorkspaceRequest(
            name: "blank",
            skills: []
        )

        let data = try JSONEncoder().encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        #expect(json["name"] as? String == "blank")
        #expect(json["hostMount"] == nil)
        #expect(json["gitStatusEnabled"] == nil)
        #expect(json["memoryEnabled"] == nil)
        #expect(json["description"] == nil)
    }

    // MARK: - Helpers

    private func makeDirectory(
        path: String = "~/workspace/test",
        name: String = "test",
        isGitRepo: Bool = false,
        gitRemote: String? = nil,
        hasAgentsMd: Bool = false,
        projectType: String? = nil,
        language: String? = nil
    ) -> HostDirectory {
        // Decode from JSON to avoid needing a memberwise init
        let json: [String: Any?] = [
            "path": path,
            "name": name,
            "isGitRepo": isGitRepo,
            "gitRemote": gitRemote,
            "hasAgentsMd": hasAgentsMd,
            "projectType": projectType,
            "language": language,
        ]
        let filtered = json.compactMapValues { $0 }
        // swiftlint:disable:next force_try
        let data = try! JSONSerialization.data(withJSONObject: filtered)
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(HostDirectory.self, from: data)
    }
}
