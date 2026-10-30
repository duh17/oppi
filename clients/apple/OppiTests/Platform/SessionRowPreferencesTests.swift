import Foundation
import Testing
@testable import Oppi

/// Corruption and unknown-value risks of the saved row appearance and the
/// remembered thread view. Both are read on every launch, so a bad stored
/// value must fall back to today's defaults instead of blanking rows.
@Suite("AppPreferences.SessionRows", .serialized)
struct SessionRowPreferencesTests {
    private func withCleanDefaults(_ body: () -> Void) {
        try? withCleanDefaultsThrowing(body)
    }

    private func withCleanDefaultsThrowing(_ body: () throws -> Void) throws {
        let defaults = UserDefaults.standard
        let keys = [AppPreferences.SessionRows.displayKey]
        let originals = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, original) in zip(keys, originals) {
                if let original { defaults.set(original, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        keys.forEach(defaults.removeObject(forKey:))
        try body()
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
            custom.showsThreadAgentSummary = false
            AppPreferences.SessionRows.setDisplay(custom)
            AppPreferences.SessionRows.setDisplay(custom)

            #expect(AppPreferences.SessionRows.display == custom)
            #expect(notifications == 1)
        }
    }

    /// Builds before the lane graph was removed saved a `showsThreadLaneGraph` choice. Those installs keep
    /// every other saved choice, and the retired key is gone from the next save.
    @Test func aSavedRetiredLaneGraphChoiceKeepsTheOtherChoicesAndIsDroppedOnTheNextSave() throws {
        try withCleanDefaultsThrowing {
            let key = AppPreferences.SessionRows.displayKey
            var stored = try #require(JSONSerialization.jsonObject(
                with: JSONEncoder().encode(SessionRowDisplay.standard)
            ) as? [String: Any])
            stored["density"] = "compact"
            stored["showsCost"] = false
            stored["showsThreadLaneGraph"] = false
            UserDefaults.standard.set(try JSONSerialization.data(withJSONObject: stored), forKey: key)

            var expected = SessionRowDisplay.standard
            expected.density = .compact
            expected.showsCost = false
            #expect(AppPreferences.SessionRows.display == expected)

            expected.showsTime = false
            AppPreferences.SessionRows.setDisplay(expected)

            let saved = try #require(UserDefaults.standard.data(forKey: key))
            let object = try #require(JSONSerialization.jsonObject(with: saved) as? [String: Any])
            #expect(object["showsThreadLaneGraph"] == nil)
            #expect(AppPreferences.SessionRows.display == expected)
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
}
