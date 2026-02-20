import Foundation
import Testing
import UIKit

@testable import Oppi

@MainActor
@Suite("PhotoLibrarySaver")
struct PhotoLibrarySaverTests {
    @Test("save routes through injected writer")
    func saveRoutesThroughInjectedWriter() {
        let original = PhotoLibrarySaver.write
        defer { PhotoLibrarySaver.write = original }

        guard let expected = UIImage(systemName: "photo") else {
            Issue.record("Failed to create system image")
            return
        }
        var capturedData: Data?

        PhotoLibrarySaver.write = { image in
            capturedData = image.pngData()
        }

        PhotoLibrarySaver.save(expected)

        #expect(capturedData == expected.pngData())
    }
}

@Suite("Image save permissions")
struct ImageSavePermissionsTests {
    private var iosRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // OppiTests
            .deletingLastPathComponent() // ios
    }

    @Test("Info.plist declares photo library add usage description")
    func infoPlistContainsPhotoLibraryAddUsageDescription() throws {
        let infoPlistURL = iosRoot.appendingPathComponent("Oppi/Resources/Info.plist")
        let data = try Data(contentsOf: infoPlistURL)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)

        guard let dict = plist as? [String: Any] else {
            Issue.record("Info.plist is not a dictionary")
            return
        }

        let value = dict["NSPhotoLibraryAddUsageDescription"] as? String
        #expect(value == "Oppi saves images from agent conversations to your photo library.")
    }

    @Test("project.yml includes NSPhotoLibraryAddUsageDescription")
    func projectYmlContainsPhotoLibraryAddUsageDescription() throws {
        let projectYmlURL = iosRoot.appendingPathComponent("project.yml")
        let text = try String(contentsOf: projectYmlURL, encoding: .utf8)

        #expect(text.contains("NSPhotoLibraryAddUsageDescription"))
        #expect(text.contains("Oppi saves images from agent conversations to your photo library."))
    }
}
