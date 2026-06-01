import UIKit

/// Shared monospaced font constants for tool timeline rows.
///
/// Uses computed properties so values update when font preferences change.
/// iPad gets one extra point for dense tool output: Apple HIG typography
/// guidance recommends default iOS/iPadOS body text at 17pt, minimum text at
/// 11pt, and larger sizes when testing shows small text is hard to read.
enum ToolFont {
    /// Small: line numbers, counters, secondary labels (10pt; 11pt on iPad)
    static var small: UIFont { font(baseSize: 10, weight: .regular) }
    static var smallBold: UIFont { font(baseSize: 10, weight: .semibold) }
    /// Regular: code content, output text, expanded labels (11pt; 12pt on iPad)
    static var regular: UIFont { font(baseSize: 11, weight: .regular) }
    static var regularBold: UIFont { font(baseSize: 11, weight: .bold) }
    /// Title: section headers, tool names (12pt; 13pt on iPad)
    static var title: UIFont { font(baseSize: 12, weight: .semibold) }
    static var titleRegular: UIFont { font(baseSize: 12, weight: .regular) }

    private static var currentIdiom: UIUserInterfaceIdiom {
        guard Thread.isMainThread else { return .phone }
        return MainActor.assumeIsolated {
            UIDevice.current.userInterfaceIdiom
        }
    }

    static func font(
        baseSize: CGFloat,
        weight: UIFont.Weight,
        idiom: UIUserInterfaceIdiom = currentIdiom
    ) -> UIFont {
        FontPreferences.codeFont.font(size: pointSize(baseSize: baseSize, idiom: idiom), weight: weight)
    }

    static func pointSize(baseSize: CGFloat, idiom: UIUserInterfaceIdiom = currentIdiom) -> CGFloat {
        idiom == .pad ? baseSize + 1 : baseSize
    }
}
