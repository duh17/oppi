import Foundation
import UIKit

/// Process-wide Core Text rasterizations, ready to copy into a glyph atlas
/// (R8 coverage, or RGBA for color emoji). Rasterizing is the whole cost of a
/// first draw: each glyph is a Core Text draw, and the first glyph in a face
/// or fallback font (italic, AppleSymbols, Apple Color Emoji) also loads that
/// font. `prewarm` does the likely set on a background queue when a renderer
/// is created, so the first screen only packs and blits.
///
/// Only bytes live here. Atlas placement, reset, and eviction stay in
/// `SSHTerminalGlyphAtlas`; a reset re-packs from this cache instead of
/// drawing again.
final class SSHTerminalGlyphRasterCache: @unchecked Sendable {
    static let shared = SSHTerminalGlyphRasterCache()

    /// Bytes held before everything is dropped. The prewarm set is well under
    /// 1 MB at scale 3; the rest is whatever the session drew.
    static let limitBytes = 8 << 20

    struct Glyph {
        var bytes: [UInt8]
        var width: Int
        var height: Int
        var color: Bool
    }

    struct Prewarm {
        var nanos: UInt64
        var glyphs: Int
    }

    private struct Key: Hashable {
        var font: UIFont
        var text: String
        var columns: Int
        var scale: CGFloat
        var cellWidth: CGFloat
        var cellHeight: CGFloat
    }

    private let lock = NSLock()
    private var entries: [Key: Glyph] = [:]
    private var bytes = 0
    /// Metrics already prewarmed (or queued), so a second renderer for the
    /// same font and scale does not queue the work again.
    private var prewarmed: Set<String> = []
    private var lastPrewarmValue: Prewarm?
    private var rasterizedValue = 0
    private let queue = DispatchQueue(label: "oppi.ssh-terminal.glyph-prewarm", qos: .utility)

    /// Last finished prewarm, for the perf bench.
    var lastPrewarm: Prewarm? {
        lock.lock()
        defer { lock.unlock() }
        return lastPrewarmValue
    }

    /// Core Text draws this cache has made, on any thread. The bench checks a
    /// prewarmed first screen adds none.
    var rasterizedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return rasterizedValue
    }

    /// Atlas-ready pixels for `text` in a `columns`-wide cell, rasterizing on
    /// a miss. Safe from any thread; two threads that miss the same key both
    /// draw and store identical bytes.
    func glyph(
        text: String, font: UIFont, cellSize: CGSize, columns: Int, scale: CGFloat
    ) -> Glyph? {
        let columns = max(1, columns)
        let key = Key(
            font: font, text: text, columns: columns, scale: scale,
            cellWidth: cellSize.width, cellHeight: cellSize.height
        )
        lock.lock()
        let hit = entries[key]
        lock.unlock()
        if let hit { return hit }
        let width = max(1, Int(ceil(cellSize.width * CGFloat(columns) * scale)))
        let height = max(1, Int(ceil(cellSize.height * scale)))
        guard let raster = SSHTerminalGlyphAtlas.rasterizeGlyph(
            text: text, font: font, width: width, height: height,
            cellSize: cellSize, columns: columns, scale: scale
        ) else { return nil }
        let glyph = Glyph(
            bytes: raster.color ? raster.bytes : Self.coverage(fromRGBA: raster.bytes),
            width: width, height: height, color: raster.color
        )
        lock.lock()
        rasterizedValue += 1
        if bytes + glyph.bytes.count > Self.limitBytes {
            entries.removeAll(keepingCapacity: true)
            bytes = 0
            prewarmed.removeAll()
        }
        if entries.updateValue(glyph, forKey: key) == nil {
            bytes += glyph.bytes.count
        }
        lock.unlock()
        return glyph
    }

    /// Queue the glyphs a terminal most likely draws first for these metrics:
    /// printable ASCII in all four faces, box drawing and block elements in
    /// regular and bold, and one glyph from each fallback font the renderer
    /// reaches (AppleSymbols, Apple Color Emoji, Nerd Font symbols) so their
    /// one-time font load happens here. Returns at once; never draws on the
    /// calling thread.
    func prewarm(metrics: SSHTerminalCellMetrics, scale: CGFloat) {
        let scale = max(scale, 1)
        let signature = [
            metrics.font.fontName, "\(metrics.font.pointSize)",
            metrics.boldFont.fontName, "\(metrics.boldFont.pointSize)",
            "\(scale)", "\(metrics.cellSize.width)x\(metrics.cellSize.height)",
        ].joined(separator: "|")
        lock.lock()
        let fresh = prewarmed.insert(signature).inserted
        lock.unlock()
        guard fresh else { return }
        queue.async { [self] in
            let start = DispatchTime.now().uptimeNanoseconds
            let cell = metrics.cellSize
            var count = 0
            func warm(_ text: String, _ font: UIFont, columns: Int = 1) {
                if glyph(text: text, font: font, cellSize: cell, columns: columns, scale: scale) != nil {
                    count += 1
                }
            }
            let faces = [(false, false), (true, false), (false, true), (true, true)].map {
                SSHTerminalMetalRenderer.styledFont(metrics: metrics, bold: $0.0, italic: $0.1)
            }
            let ascii = (0x21...0x7E).compactMap { Unicode.Scalar($0).map { String($0) } }
            let boxes = (0x2500...0x259F).compactMap { Unicode.Scalar($0).map { String($0) } }
            for text in ascii { warm(text, faces[0]) }
            for text in boxes { warm(text, faces[0]) }
            for text in ascii { warm(text, faces[1]) }
            for text in boxes { warm(text, faces[1]) }
            for text in ascii { warm(text, faces[2]) }
            for text in ascii { warm(text, faces[3]) }
            // Fallback fonts: the first draw from each one loads it.
            warm("\u{23F9}", faces[0])
            warm("\u{1F642}", faces[0], columns: 2)
            if let symbols = NerdFontSymbols.font(size: metrics.font.pointSize) {
                for scalar in [0xE0A0, 0xE0B0, 0xE0B2] {
                    if let unit = Unicode.Scalar(scalar) { warm(String(unit), symbols) }
                }
            }
            let result = Prewarm(
                nanos: DispatchTime.now().uptimeNanoseconds &- start,
                glyphs: count
            )
            lock.lock()
            lastPrewarmValue = result
            lock.unlock()
        }
    }

    /// Block until queued prewarm work has finished. Tests and the perf bench
    /// only; the app never waits for it.
    func waitForPrewarm() {
        queue.sync {}
    }

    private static func coverage(fromRGBA bytes: [UInt8]) -> [UInt8] {
        let pixels = bytes.count / 4
        var out = [UInt8](repeating: 0, count: pixels)
        var i = 0
        while i < pixels {
            out[i] = bytes[i * 4 + 3]
            i += 1
        }
        return out
    }
}
