import CoreGraphics
import CoreText
import Foundation

/// The font formulas draw in, and the typesetting data its OpenType MATH
/// table carries.
///
/// iOS ships STIX Two Math as a system font. Its MATH table holds what a
/// renderer would otherwise guess: the math axis, fraction and script shifts,
/// size variants and assembly parts for delimiters, radicals and big
/// operators, italic corrections, and where accents attach. The layout engine
/// reads all of it here. Without the font, Times New Roman draws with the
/// STIX constants and no variants, so delimiters keep their natural size.
final class MathFont: @unchecked Sendable {
    static let shared = MathFont()

    /// SF Regular's stem (0.085 em) in math ems once math matches the body
    /// text's x-height. STIX's stems are about 28% thinner, so beside body
    /// text formulas read lighter, most in dark mode; glyphs and rules draw
    /// at this weight instead.
    private static let bodyStemWidth: CGFloat = 0.079
    /// STIX's own stem, in ems.
    private static let stixStemWidth: CGFloat = 0.057

    /// Outline stroke drawn with every glyph, in ems, that brings STIX's
    /// stems to the body text's weight; 0 (the Times fallback) draws fill
    /// only. A stroke adds half its width to each side of a stem.
    let strokeWidth: CGFloat

    /// Typesetting constants as fractions of the font size (1 = 1 em).
    struct Constants: Sendable {
        var scriptScale: CGFloat = 0.70
        var scriptScriptScale: CGFloat = 0.55
        var displayOperatorMinHeight: CGFloat = 1.800
        var axisHeight: CGFloat = 0.258
        var accentBaseHeight: CGFloat = 0.480
        var subscriptShiftDown: CGFloat = 0.210
        var subscriptTopMax: CGFloat = 0.368
        var subscriptBaselineDropMin: CGFloat = 0.160
        var superscriptShiftUp: CGFloat = 0.360
        var superscriptShiftUpCramped: CGFloat = 0.252
        var superscriptBottomMin: CGFloat = 0.120
        var superscriptBaselineDropMax: CGFloat = 0.230
        var subSuperscriptGapMin: CGFloat = 0.150
        var superscriptBottomMaxWithSubscript: CGFloat = 0.380
        var spaceAfterScript: CGFloat = 0.040
        var upperLimitGapMin: CGFloat = 0.135
        var upperLimitBaselineRiseMin: CGFloat = 0.300
        var lowerLimitGapMin: CGFloat = 0.135
        var lowerLimitBaselineDropMin: CGFloat = 0.670
        var stackTopShiftUp: CGFloat = 0.470
        var stackTopDisplayStyleShiftUp: CGFloat = 0.780
        var stackBottomShiftDown: CGFloat = 0.385
        var stackBottomDisplayStyleShiftDown: CGFloat = 0.690
        var stackGapMin: CGFloat = 0.150
        var stackDisplayStyleGapMin: CGFloat = 0.300
        var stretchStackTopShiftUp: CGFloat = 0.800
        var stretchStackBottomShiftDown: CGFloat = 0.590
        var stretchStackGapAboveMin: CGFloat = 0.068
        var stretchStackGapBelowMin: CGFloat = 0.068
        var fractionNumeratorShiftUp: CGFloat = 0.585
        var fractionNumeratorDisplayStyleShiftUp: CGFloat = 0.640
        var fractionDenominatorShiftDown: CGFloat = 0.585
        var fractionDenominatorDisplayStyleShiftDown: CGFloat = 0.640
        var fractionNumeratorGapMin: CGFloat = 0.068
        var fractionNumDisplayStyleGapMin: CGFloat = 0.150
        var fractionRuleThickness: CGFloat = 0.068
        var fractionDenominatorGapMin: CGFloat = 0.068
        var fractionDenomDisplayStyleGapMin: CGFloat = 0.150
        var overbarVerticalGap: CGFloat = 0.175
        var overbarRuleThickness: CGFloat = 0.068
        var overbarExtraAscender: CGFloat = 0.068
        var underbarVerticalGap: CGFloat = 0.175
        var underbarRuleThickness: CGFloat = 0.068
        var underbarExtraDescender: CGFloat = 0.068
        var radicalVerticalGap: CGFloat = 0.085
        var radicalDisplayStyleVerticalGap: CGFloat = 0.170
        var radicalRuleThickness: CGFloat = 0.068
        var radicalExtraAscender: CGFloat = 0.078
        var radicalKernBeforeDegree: CGFloat = 0.065
        var radicalKernAfterDegree: CGFloat = -0.335
        var radicalDegreeBottomRaise: CGFloat = 0.55
    }

    /// One piece of a stretched glyph, in font units.
    struct AssemblyPart: Sendable {
        let glyph: CGGlyph
        let startConnector: CGFloat
        let endConnector: CGFloat
        let fullAdvance: CGFloat
        let isExtender: Bool
    }

    /// Larger drawings of one glyph, smallest first, and the parts that build
    /// it to any size past the largest.
    struct Construction: Sendable {
        let variants: [CGGlyph]
        let assembly: [AssemblyPart]
    }

    let constants: Constants
    let unitsPerEm: CGFloat
    /// Smallest overlap between assembly parts, in font units.
    let minConnectorOverlap: CGFloat
    private let base: CTFont
    private let vertical: [CGGlyph: Construction]
    private let horizontal: [CGGlyph: Construction]
    private let italicCorrections: [CGGlyph: CGFloat]
    private let topAccentAttachments: [CGGlyph: CGFloat]
    private let lock = NSLock()
    private var sized: [CGFloat: CTFont] = [:]

    private init() {
        let math = CTFontCreateWithName("STIXTwoMath-Regular" as CFString, 16, nil)
        let table = CTFontCopyPostScriptName(math) as String == "STIXTwoMath-Regular"
            ? CTFontCopyTable(math, CTFontTableTag(0x4D41_5448), []) as Data?
            : nil
        if let table,
           let parsed = MathTableReader(data: table, unitsPerEm: CGFloat(CTFontGetUnitsPerEm(math))) {
            base = math
            var constants = parsed.constants
            let stem = Self.bodyStemWidth
            constants.fractionRuleThickness = max(constants.fractionRuleThickness, stem)
            constants.overbarRuleThickness = max(constants.overbarRuleThickness, stem)
            constants.underbarRuleThickness = max(constants.underbarRuleThickness, stem)
            constants.radicalRuleThickness = max(constants.radicalRuleThickness, stem)
            self.constants = constants
            strokeWidth = Self.bodyStemWidth - Self.stixStemWidth
            minConnectorOverlap = parsed.minConnectorOverlap
            vertical = parsed.vertical
            horizontal = parsed.horizontal
            italicCorrections = parsed.italicCorrections
            topAccentAttachments = parsed.topAccentAttachments
        } else {
            base = CTFontCreateWithName("TimesNewRomanPSMT" as CFString, 16, nil)
            constants = Constants()
            strokeWidth = 0
            minConnectorOverlap = 0
            vertical = [:]
            horizontal = [:]
            italicCorrections = [:]
            topAccentAttachments = [:]
        }
        unitsPerEm = CGFloat(CTFontGetUnitsPerEm(base))
    }

    func font(size: CGFloat) -> CTFont {
        lock.lock()
        defer { lock.unlock() }
        if let font = sized[size] { return font }
        let font = CTFontCreateCopyWithAttributes(base, size, nil, nil)
        sized[size] = font
        return font
    }

    /// The font's own glyph for one character, or nil when it has none.
    func glyph(for character: Character) -> CGGlyph? {
        let utf16 = Array(String(character).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
        guard CTFontGetGlyphsForCharacters(base, utf16, &glyphs, utf16.count),
              glyphs[0] != 0 else { return nil }
        return glyphs[0]
    }

    func verticalConstruction(_ glyph: CGGlyph) -> Construction? { vertical[glyph] }
    func horizontalConstruction(_ glyph: CGGlyph) -> Construction? { horizontal[glyph] }

    /// Italic correction in ems.
    func italicCorrection(_ glyph: CGGlyph) -> CGFloat? {
        italicCorrections[glyph].map { $0 / unitsPerEm }
    }

    /// Where an accent centres over this glyph, in ems from its origin.
    func topAccentAttachment(_ glyph: CGGlyph) -> CGFloat? {
        topAccentAttachments[glyph].map { $0 / unitsPerEm }
    }

    /// Height of the smallest x-height letter relative to the font size.
    /// Callers size math so its x-height matches the surrounding text's.
    var xHeightRatio: CGFloat {
        CTFontGetXHeight(base) / CTFontGetSize(base)
    }

    /// The math size whose x-height matches `font`'s.
    func fontSize(matchingXHeightOf font: CTFont) -> CGFloat {
        let ratio = xHeightRatio
        guard ratio > 0 else { return CTFontGetSize(font) }
        return CTFontGetXHeight(font) / ratio
    }
}

// MARK: - MATH table

/// Reads the parts of an OpenType MATH table the layout engine uses. Any
/// offset that runs past the table fails the whole read.
private struct MathTableReader {
    var constants = MathFont.Constants()
    var minConnectorOverlap: CGFloat = 0
    var vertical: [CGGlyph: MathFont.Construction] = [:]
    var horizontal: [CGGlyph: MathFont.Construction] = [:]
    var italicCorrections: [CGGlyph: CGFloat] = [:]
    var topAccentAttachments: [CGGlyph: CGFloat] = [:]

    private let bytes: [UInt8]

    init?(data: Data, unitsPerEm: CGFloat) {
        bytes = [UInt8](data)
        guard unitsPerEm > 0, let constantsOffset = u16(4), let glyphInfoOffset = u16(6),
              let variantsOffset = u16(8) else { return nil }
        guard readConstants(at: constantsOffset, unitsPerEm: unitsPerEm),
              readGlyphInfo(at: glyphInfoOffset),
              readVariants(at: variantsOffset) else { return nil }
    }

    private func u16(_ offset: Int) -> Int? {
        guard offset >= 0, offset + 1 < bytes.count else { return nil }
        return Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
    }

    private func i16(_ offset: Int) -> Int? {
        u16(offset).map { Int(Int16(truncatingIfNeeded: $0)) }
    }

    private mutating func readConstants(at start: Int, unitsPerEm: CGFloat) -> Bool {
        guard let script = i16(start), let scriptScript = i16(start + 2),
              let operatorMin = u16(start + 6) else { return false }
        var values: [CGFloat] = []
        for index in 0 ..< 51 {
            guard let value = i16(start + 8 + 4 * index) else { return false }
            values.append(CGFloat(value) / unitsPerEm)
        }
        guard let degreeRaise = i16(start + 8 + 4 * 51) else { return false }
        var c = MathFont.Constants()
        c.scriptScale = CGFloat(script) / 100
        c.scriptScriptScale = CGFloat(scriptScript) / 100
        c.displayOperatorMinHeight = CGFloat(operatorMin) / unitsPerEm
        c.axisHeight = values[1]
        c.accentBaseHeight = values[2]
        c.subscriptShiftDown = values[4]
        c.subscriptTopMax = values[5]
        c.subscriptBaselineDropMin = values[6]
        c.superscriptShiftUp = values[7]
        c.superscriptShiftUpCramped = values[8]
        c.superscriptBottomMin = values[9]
        c.superscriptBaselineDropMax = values[10]
        c.subSuperscriptGapMin = values[11]
        c.superscriptBottomMaxWithSubscript = values[12]
        c.spaceAfterScript = values[13]
        c.upperLimitGapMin = values[14]
        c.upperLimitBaselineRiseMin = values[15]
        c.lowerLimitGapMin = values[16]
        c.lowerLimitBaselineDropMin = values[17]
        c.stackTopShiftUp = values[18]
        c.stackTopDisplayStyleShiftUp = values[19]
        c.stackBottomShiftDown = values[20]
        c.stackBottomDisplayStyleShiftDown = values[21]
        c.stackGapMin = values[22]
        c.stackDisplayStyleGapMin = values[23]
        c.stretchStackTopShiftUp = values[24]
        c.stretchStackBottomShiftDown = values[25]
        c.stretchStackGapAboveMin = values[26]
        c.stretchStackGapBelowMin = values[27]
        c.fractionNumeratorShiftUp = values[28]
        c.fractionNumeratorDisplayStyleShiftUp = values[29]
        c.fractionDenominatorShiftDown = values[30]
        c.fractionDenominatorDisplayStyleShiftDown = values[31]
        c.fractionNumeratorGapMin = values[32]
        c.fractionNumDisplayStyleGapMin = values[33]
        c.fractionRuleThickness = values[34]
        c.fractionDenominatorGapMin = values[35]
        c.fractionDenomDisplayStyleGapMin = values[36]
        c.overbarVerticalGap = values[39]
        c.overbarRuleThickness = values[40]
        c.overbarExtraAscender = values[41]
        c.underbarVerticalGap = values[42]
        c.underbarRuleThickness = values[43]
        c.underbarExtraDescender = values[44]
        c.radicalVerticalGap = values[45]
        c.radicalDisplayStyleVerticalGap = values[46]
        c.radicalRuleThickness = values[47]
        c.radicalExtraAscender = values[48]
        c.radicalKernBeforeDegree = values[49]
        c.radicalKernAfterDegree = values[50]
        c.radicalDegreeBottomRaise = CGFloat(degreeRaise) / 100
        constants = c
        return true
    }

    private func coverage(at offset: Int) -> [CGGlyph]? {
        guard let format = u16(offset), let count = u16(offset + 2) else { return nil }
        var glyphs: [CGGlyph] = []
        switch format {
        case 1:
            for index in 0 ..< count {
                guard let glyph = u16(offset + 4 + 2 * index) else { return nil }
                glyphs.append(CGGlyph(glyph))
            }
        case 2:
            for index in 0 ..< count {
                let record = offset + 4 + 6 * index
                guard let first = u16(record), let last = u16(record + 2), first <= last else { return nil }
                glyphs.append(contentsOf: (first ... last).map { CGGlyph($0) })
            }
        default:
            return nil
        }
        return glyphs
    }

    /// A coverage table and its parallel array of MathValueRecords.
    private func valueTable(at offset: Int) -> [CGGlyph: CGFloat]? {
        guard let coverageOffset = u16(offset), let count = u16(offset + 2),
              let glyphs = coverage(at: offset + coverageOffset),
              glyphs.count >= count else { return nil }
        var values: [CGGlyph: CGFloat] = [:]
        for index in 0 ..< count {
            guard let value = i16(offset + 4 + 4 * index) else { return nil }
            values[glyphs[index]] = CGFloat(value)
        }
        return values
    }

    private mutating func readGlyphInfo(at start: Int) -> Bool {
        guard let italicsOffset = u16(start), let accentOffset = u16(start + 2) else { return false }
        if italicsOffset != 0 {
            guard let table = valueTable(at: start + italicsOffset) else { return false }
            italicCorrections = table
        }
        if accentOffset != 0 {
            guard let table = valueTable(at: start + accentOffset) else { return false }
            topAccentAttachments = table
        }
        return true
    }

    private mutating func readVariants(at start: Int) -> Bool {
        guard let overlap = u16(start),
              let verticalCoverageOffset = u16(start + 2),
              let horizontalCoverageOffset = u16(start + 4),
              let verticalCount = u16(start + 6),
              let horizontalCount = u16(start + 8) else { return false }
        minConnectorOverlap = CGFloat(overlap)
        let verticalGlyphs = verticalCoverageOffset == 0 ? [] : coverage(at: start + verticalCoverageOffset)
        let horizontalGlyphs = horizontalCoverageOffset == 0 ? [] : coverage(at: start + horizontalCoverageOffset)
        guard let verticalGlyphs, let horizontalGlyphs,
              verticalGlyphs.count >= verticalCount,
              horizontalGlyphs.count >= horizontalCount else { return false }
        for index in 0 ..< verticalCount {
            guard let offset = u16(start + 10 + 2 * index),
                  let construction = construction(at: start + offset) else { return false }
            vertical[verticalGlyphs[index]] = construction
        }
        for index in 0 ..< horizontalCount {
            guard let offset = u16(start + 10 + 2 * (verticalCount + index)),
                  let construction = construction(at: start + offset) else { return false }
            horizontal[horizontalGlyphs[index]] = construction
        }
        return true
    }

    private func construction(at start: Int) -> MathFont.Construction? {
        guard let assemblyOffset = u16(start), let variantCount = u16(start + 2) else { return nil }
        var variants: [CGGlyph] = []
        for index in 0 ..< variantCount {
            guard let glyph = u16(start + 4 + 4 * index) else { return nil }
            variants.append(CGGlyph(glyph))
        }
        var parts: [MathFont.AssemblyPart] = []
        if assemblyOffset != 0 {
            let assembly = start + assemblyOffset
            guard let partCount = u16(assembly + 4) else { return nil }
            for index in 0 ..< partCount {
                let record = assembly + 6 + 10 * index
                guard let glyph = u16(record), let startConnector = u16(record + 2),
                      let endConnector = u16(record + 4), let advance = u16(record + 6),
                      let flags = u16(record + 8) else { return nil }
                parts.append(MathFont.AssemblyPart(
                    glyph: CGGlyph(glyph),
                    startConnector: CGFloat(startConnector),
                    endConnector: CGFloat(endConnector),
                    fullAdvance: CGFloat(advance),
                    isExtender: flags & 1 == 1
                ))
            }
        }
        return MathFont.Construction(variants: variants, assembly: parts)
    }
}
