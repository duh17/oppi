import SwiftUI

/// When auxiliary side content opens as a trailing column instead of a sheet.
///
/// Chat keeps an explicit sheet unless a vertical toolbar edge is present and
/// the width is regular. These surfaces follow the width half of that rule:
/// a trailing column in regular width, the existing sheet or stack in compact.
/// The rail edge is not required. iPad and Duo's inner portrait are regular
/// without a vertical bar, and folding must not turn an open column back into
/// a sheet. Compact, including Duo's cover display, keeps the sheet so an
/// inspector does not adapt into a second one.
enum TrailingSidePanelPolicy {
    static func usesTrailingColumn(horizontalSizeClass: UserInterfaceSizeClass?) -> Bool {
        horizontalSizeClass == .regular
    }
}
