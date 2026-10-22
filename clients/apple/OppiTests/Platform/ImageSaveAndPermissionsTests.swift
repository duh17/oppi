import Foundation
import Testing

@Suite("Image save permissions")
@MainActor
struct ImageSavePermissionsTests {
    /// The built app's Info.plist (the tests run hosted in Oppi.app), the artifact App Review reads.
    @Test("Info.plist declares photo library add usage description")
    func infoPlistContainsPhotoLibraryAddUsageDescription() {
        let value = Bundle.main.object(forInfoDictionaryKey: "NSPhotoLibraryAddUsageDescription") as? String
        #expect(value == "Oppi saves images from agent conversations to your photo library.")
    }
}
