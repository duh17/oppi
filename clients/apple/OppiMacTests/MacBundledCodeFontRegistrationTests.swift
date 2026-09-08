import Foundation
import Testing
@testable import Oppi

@Suite("MacBundledCodeFontRegistration")
struct MacBundledCodeFontRegistrationTests {
    @Test func fontFileURLsKeepOnlyOpenTypeFiles() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("oppi-font-reg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data().write(to: folder.appendingPathComponent("FiraCode-Regular.ttf"))
        try Data().write(to: folder.appendingPathComponent("FiraCode-Bold.otf"))
        try Data().write(to: folder.appendingPathComponent("LICENSES.md"))
        let names = Set(
            MacBundledCodeFontRegistration.fontFileURLs(in: folder).map(\.lastPathComponent)
        )
        #expect(names == ["FiraCode-Regular.ttf", "FiraCode-Bold.otf"])
    }
}
