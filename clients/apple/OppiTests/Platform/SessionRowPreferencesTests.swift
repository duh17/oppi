import Foundation
import Testing
@testable import Oppi

/// Corruption and unknown-value risks of the saved row appearance and the
/// remembered thread view. Both are read on every launch, so a bad stored
/// value must fall back to today's defaults instead of blanking rows.
@Suite("AppPreferences.SessionRows", .serialized)
struct SessionRowPreferencesTests {
    private func withCleanDefaults(_ body: () -> Void) {
        let defaults = UserDefaults.standard
        let keys = [
            AppPreferences.SessionRows.displayKey,
            AppPreferences.SessionRows.threadDetailModeKey,
        ]
        let originals = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, original) in zip(keys, originals) {
                if let original { defaults.set(original, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        keys.forEach(defaults.removeObject(forKey:))
        body()
    }

    @Test func savedDisplaySurvivesRereadAndNotifiesOnlyOnChange() {
        withCleanDefaults {
            #expect(AppPreferences.SessionRows.display == .standard)

            var notifications = 0
            let token = NotificationCenter.default.addObserver(
                forName: AppPreferences.SessionRows.didChangeNotification, object: nil, queue: .main
            ) { _ in notifications += 1 }
            defer { NotificationCenter.default.removeObserver(token) }

            var custom = SessionRowDisplay.standard
            custom.density = .compact
            custom.showsCost = false
            custom.showsThreadLaneGraph = false
            AppPreferences.SessionRows.setDisplay(custom)
            AppPreferences.SessionRows.setDisplay(custom)

            #expect(AppPreferences.SessionRows.display == custom)
            #expect(notifications == 1)
        }
    }

    @Test func malformedOrUnrecognizedDisplayFallsBackToStandard() {
        withCleanDefaults {
            let key = AppPreferences.SessionRows.displayKey
            let defaults = UserDefaults.standard

            defaults.set(Data("not json".utf8), forKey: key)
            #expect(AppPreferences.SessionRows.display == .standard)

            defaults.set("compact", forKey: key)
            #expect(AppPreferences.SessionRows.display == .standard)

            // A valid shape with an unknown density must not half-apply its other fields.
            var stored = (try? JSONSerialization.jsonObject(
                with: JSONEncoder().encode(SessionRowDisplay.standard)
            ) as? [String: Any]) ?? [:]
            stored["density"] = "spacious"
            stored["showsCost"] = false
            defaults.set(try? JSONSerialization.data(withJSONObject: stored), forKey: key)
            #expect(AppPreferences.SessionRows.display == .standard)
        }
    }

    @Test func threadDetailModeIsRememberedAndUnknownValuesOpenOutline() {
        withCleanDefaults {
            #expect(AppPreferences.SessionRows.threadDetailMode == .outline)

            AppPreferences.SessionRows.setThreadDetailMode(.timeline)
            #expect(AppPreferences.SessionRows.threadDetailMode == .timeline)

            UserDefaults.standard.set("gantt", forKey: AppPreferences.SessionRows.threadDetailModeKey)
            #expect(AppPreferences.SessionRows.threadDetailMode == .outline)
        }
    }
}
