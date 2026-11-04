import Foundation

/// How a book's chapters are shown: one page at a time, or one scrolling column.
///
/// A device setting, like the reader's text size: the same book opens as pages on
/// a phone and as the column it always was when the person asks for that.
enum BookReaderPageMode: String, Codable, CaseIterable, Equatable {
    case pages
    case scrolling

    var displayName: String {
        switch self {
        case .pages: String(localized: "Pages")
        case .scrolling: String(localized: "Scrolling")
        }
    }
}

/// The mode is remembered per device in preferences, the way the reader's
/// viewing preferences are, and defaults to pages.
struct BookReaderPageModeStore {
    static let preferenceKey = "\(AppIdentifiers.subsystem).book.pageMode"

    var defaults: UserDefaults = .standard

    var mode: BookReaderPageMode {
        get {
            guard let raw = defaults.string(forKey: Self.preferenceKey),
                  let mode = BookReaderPageMode(rawValue: raw) else { return .pages }
            return mode
        }
        nonmutating set {
            defaults.set(newValue.rawValue, forKey: Self.preferenceKey)
        }
    }
}
