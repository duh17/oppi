import Foundation
import XCTest

/// Files bundled into OppiE2ETests (project.yml adds them as resources). Tests never read the
/// source tree: pool builds compile `#filePath` to a mapped path that does not exist.
enum E2EFixtures {
    private final class BundleAnchor {}

    static func data(_ name: String, _ ext: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle(for: BundleAnchor.self).url(forResource: name, withExtension: ext),
            "\(name).\(ext) is not in the OppiE2ETests bundle"
        )
        return try Data(contentsOf: url)
    }
}
