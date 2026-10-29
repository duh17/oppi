import Foundation
import Testing
@testable import Oppi

@MainActor
@Suite("Test launch contract")
struct TestLaunchContractTests {
    private let domain = "test-launch-contract-\(UUID().uuidString)"
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("test-launch-contract-\(UUID().uuidString)", isDirectory: true)

    private func makeDefaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: domain))
    }

    private func cleanUp(_ defaults: UserDefaults) {
        defaults.removePersistentDomain(forName: domain)
        try? FileManager.default.removeItem(at: directory)
    }

    private func apply(_ token: String?, _ defaults: UserDefaults) {
        TestLaunchContract.applyReset(token: token, defaults: defaults, domains: [domain], directories: [directory])
    }

    private func writeDraft() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("draft".utf8).write(to: directory.appendingPathComponent("drafts-v1.json"))
    }

    @Test func newTokenClearsSavedStateAndPinsWhatsNewForThisBuild() throws {
        let defaults = try makeDefaults()
        defer { cleanUp(defaults) }
        defaults.set(1.5, forKey: "reader.speed")
        defaults.set("0.0.1 (1)", forKey: WhatsNewManager.lastSeenVersionKey)
        try writeDraft()

        apply("run-1", defaults)

        #expect(defaults.object(forKey: "reader.speed") == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(defaults.string(forKey: WhatsNewManager.lastSeenVersionKey) == WhatsNewManager.currentVersion)
    }

    @Test func sameTokenOnRelaunchKeepsState() throws {
        let defaults = try makeDefaults()
        defer { cleanUp(defaults) }
        apply("run-1", defaults)
        defaults.set(1.5, forKey: "reader.speed")
        try writeDraft()

        apply("run-1", defaults)

        #expect(defaults.double(forKey: "reader.speed") == 1.5)
        #expect(FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func nextTokenClearsAgain() throws {
        let defaults = try makeDefaults()
        defer { cleanUp(defaults) }
        apply("run-1", defaults)
        defaults.set(1.5, forKey: "reader.speed")
        try writeDraft()

        apply("run-2", defaults)

        #expect(defaults.object(forKey: "reader.speed") == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func launchWithoutATokenChangesNothing() throws {
        let defaults = try makeDefaults()
        defer { cleanUp(defaults) }
        defaults.set(1.5, forKey: "reader.speed")
        try writeDraft()

        apply(nil, defaults)

        #expect(defaults.double(forKey: "reader.speed") == 1.5)
        #expect(FileManager.default.fileExists(atPath: directory.path))
    }
}
