import Foundation
import UIKit

/// Pictures of the running game: the engine's own frame as PNG, read from
/// its viewport (a view snapshot cannot see the engine's Metal layer).
@MainActor
enum GodotFrameCapture {
    /// The current frame as PNG data, or nil while no game runs.
    static func png(from host: GodotEngineHost) -> Data? {
        host.liveRuntime?.capturePNG()
    }

    /// `png` as it goes to a controller: as is, or scaled down so its longer
    /// side is at most `maxSize` pixels; with its pixel size.
    static func fitted(_ png: Data, maxSize: Int?) -> (data: Data, width: Int, height: Int)? {
        guard let image = UIImage(data: png, scale: 1), let cg = image.cgImage else { return nil }
        let longer = max(cg.width, cg.height)
        guard let maxSize, maxSize > 0, longer > maxSize else { return (png, cg.width, cg.height) }
        let factor = CGFloat(maxSize) / CGFloat(longer)
        let size = CGSize(width: (CGFloat(cg.width) * factor).rounded(), height: (CGFloat(cg.height) * factor).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let data = UIGraphicsImageRenderer(size: size, format: format).pngData { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return (data, Int(size.width), Int(size.height))
    }

    /// The app's memory footprint in MB, as the system counts it against its limit.
    nonisolated static func footprintMegabytes() -> Double? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : nil
    }

    /// The current frame as an image, at the surface's scale.
    static func image(from host: GodotEngineHost) -> UIImage? {
        png(from: host).flatMap { UIImage(data: $0, scale: host.surface.traitCollection.displayScale) }
    }
}
