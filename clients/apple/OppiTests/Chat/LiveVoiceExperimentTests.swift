import Testing
import UIKit
@testable import Oppi

/// Live Voice is an experiment (Settings → Experiments), off by default. These
/// tests share the process-wide defaults, so they run one at a time and put the
/// flag back as they found it.
@Suite("Live Voice experiment", .serialized)
@MainActor
struct LiveVoiceExperimentTests {
    private static let reason = "Live Voice is an experiment. Turn it on in Settings → Experiments."

    /// Runs `body` with the experiment set to `enabled`, then restores the stored value.
    private func withExperiment(_ enabled: Bool?, _ body: () async throws -> Void) async rethrows {
        let key = AppPreferences.Experiments.liveVoiceKey
        let before = UserDefaults.standard.object(forKey: key)
        if let enabled { UserDefaults.standard.set(enabled, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        defer {
            if let before { UserDefaults.standard.set(before, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        try await body()
    }

    @Test("The experiment is off until someone turns it on")
    func offByDefault() async {
        await withExperiment(nil) {
            #expect(!AppPreferences.Experiments.liveVoiceEnabled)
        }
    }

    @Test("The chat composer offers Live Voice only with the experiment on and the server advertising it")
    func chatEntryNeedsExperimentAndCapability() async {
        let (connection, _) = makeTestConnection(sessionId: "live-voice-entry")
        let chat = ChatViewController(
            sessionId: "live-voice-entry",
            connection: connection,
            navigation: AppNavigation()
        )

        for experiment in [false, true] {
            await withExperiment(experiment) {
                // A server older than 0.53.0, or one whose voice backend is not set up, advertises nothing.
                connection.setSplitStreamCapabilitiesForTesting(liveVoice: false)
                #expect(chat.liveVoiceEntry == nil)

                connection.setSplitStreamCapabilitiesForTesting(liveVoice: true)
                #expect((chat.liveVoiceEntry != nil) == experiment)

                // The next connect reads /server/info again; a backend that went away hides the entry.
                connection.setSplitStreamCapabilitiesForTesting(liveVoice: false)
                #expect(chat.liveVoiceEntry == nil)
            }
        }
    }

    @Test("Quick Session offers Live Voice only with the experiment on and the server advertising it")
    func quickSessionEntryNeedsExperimentAndCapability() async throws {
        let root = try makeQuickSessionRoot(liveVoice: true)
        let model = QuickSessionModel(root: root)

        await withExperiment(false) { #expect(model.liveVoiceEntry == nil) }
        await withExperiment(true) { #expect(model.liveVoiceEntry != nil) }

        try #require(root.coordinator.activeConnection).setSplitStreamCapabilitiesForTesting(liveVoice: false)
        await withExperiment(true) { #expect(model.liveVoiceEntry == nil) }
    }

    @Test("A Live Voice start with the experiment off says why, keeps the draft, and starts nothing")
    func requestedStartExplainsTheExperiment() async throws {
        let store = ComposerDraftStore(
            fileURL: FileManager.default.temporaryDirectory
                .appending(path: "live-voice-experiment-\(UUID().uuidString).json", directoryHint: .notDirectory),
            saveDelay: .seconds(60)
        )
        await store.load()
        store.setQuickSessionDraftText("half-typed thought")
        let root = try makeQuickSessionRoot(liveVoice: true, composerDraftStore: store)
        let model = QuickSessionModel(root: root)
        root.navigation.pendingQuickSessionStart = QuickSessionStart(mode: .liveVoice)

        await withExperiment(false) {
            await model.setUp(requestDictation: {}, focusComposer: {})
        }

        #expect(model.error == Self.reason)
        #expect(model.text == "half-typed thought")
        #expect(!model.isCreating)
    }

    @Test("A Live Voice start with the experiment on is not refused for the experiment")
    func requestedStartWithExperimentOnIsNotRefusedForIt() async throws {
        let root = try makeQuickSessionRoot(liveVoice: true)
        let model = QuickSessionModel(root: root)
        root.navigation.pendingQuickSessionStart = QuickSessionStart(mode: .liveVoice)

        await withExperiment(true) {
            await model.setUp(requestDictation: {}, focusComposer: {})
        }

        // Past the experiment gate the next gate is the workspace: this fixture has none, so
        // that is where the start stops. Asserting it proves setUp got past the experiment check
        // rather than never reaching a start at all.
        #expect(model.error == "Choose a workspace for Live Voice.")
    }

    private func makeQuickSessionRoot(
        liveVoice: Bool,
        composerDraftStore: ComposerDraftStore? = nil
    ) throws -> AppRootEnvironment {
        let client = APIClient(baseURL: try #require(URL(string: "http://127.0.0.1:1")), token: "sk_test", configuration: .ephemeral)
        let ready = try makeTestAppRoot(readyServerId: "sha256:live-voice-\(UUID().uuidString)", apiClient: client)
        let connection = try #require(ready.coordinator.activeConnection)
        connection.setSplitStreamCapabilitiesForTesting(liveVoice: liveVoice)
        // A cold launch waits for the workspace list; this server has loaded its (empty) one.
        connection.workspaceStore.isLoaded = true
        guard let composerDraftStore else { return ready }
        return makeTestAppRoot(coordinator: ready.coordinator, composerDraftStore: composerDraftStore)
    }
}

/// The Experiments page: every toggle writes the setting it names, the Durable
/// Sessions default row follows its parent, and the root count includes Live Voice.
@Suite("Settings Experiments page", .serialized)
@MainActor
struct SettingsExperimentsPageTests {
    @Test("Each toggle saves its own experiment and Start Sessions as Durable shows only with Durable Sessions")
    func togglesSaveTheirExperiments() async throws {
        let defaults = try #require(UserDefaults(suiteName: "SettingsExperimentsPageTests-\(UUID().uuidString)"))
        let navigation = AppNavigation()
        // Session Threads lives in the process-wide defaults: start it off, put it back after.
        let sessionThreadsBefore = navigation.sessionThreadsEnabled
        navigation.sessionThreadsEnabled = false
        defer { navigation.sessionThreadsEnabled = sessionThreadsBefore }
        let page = SettingsExperimentsViewController(navigation: navigation, defaults: defaults)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 1200)
        window.rootViewController = page
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }

        func toggle(_ id: String) async -> UISwitch? {
            for _ in 0..<100 {
                page.view.layoutIfNeeded()
                if let found = Self.switches(in: page.view).first(where: { $0.accessibilityIdentifier == id }) { return found }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return nil
        }
        func flip(_ toggle: UISwitch) {
            toggle.isOn.toggle()
            toggle.sendActions(for: .valueChanged)
        }

        // Everything starts off, and the default row is hidden until Durable Sessions is on.
        for id in ["sessionThreads", "experiments.liveVoice", "experiments.durableSessions"] {
            let found = await toggle("settings.\(id)")
            #expect(found?.isOn == false, "\(id) should start off")
        }
        #expect(Self.switches(in: page.view).allSatisfy { $0.accessibilityIdentifier != "settings.experiments.durableSessionsDefault" })

        flip(try #require(await toggle("settings.experiments.liveVoice")))
        #expect(defaults.bool(forKey: AppPreferences.Experiments.liveVoiceKey))

        flip(try #require(await toggle("settings.sessionThreads")))
        #expect(navigation.sessionThreadsEnabled)

        flip(try #require(await toggle("settings.experiments.durableSessions")))
        #expect(defaults.bool(forKey: AppPreferences.Experiments.durableSessionsKey))
        let defaultRow = try #require(await toggle("settings.experiments.durableSessionsDefault"))
        flip(defaultRow)
        #expect(defaults.bool(forKey: AppPreferences.Experiments.durableSessionsDefaultKey))

        flip(try #require(await toggle("settings.experiments.durableSessions")))
        #expect(!defaults.bool(forKey: AppPreferences.Experiments.durableSessionsKey))
        for _ in 0..<100 where Self.switches(in: page.view).contains(where: { $0.accessibilityIdentifier == "settings.experiments.durableSessionsDefault" }) {
            try await Task.sleep(for: .milliseconds(20))
            page.view.layoutIfNeeded()
        }
        #expect(Self.switches(in: page.view).allSatisfy { $0.accessibilityIdentifier != "settings.experiments.durableSessionsDefault" })
    }

    @Test("The root count includes Live Voice")
    func enabledCountIncludesLiveVoice() {
        let key = AppPreferences.Experiments.liveVoiceKey
        let before = UserDefaults.standard.object(forKey: key)
        defer {
            if let before { UserDefaults.standard.set(before, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.set(false, forKey: key)
        let without = SettingsExperimentsViewController.enabledCount(sessionThreadsEnabled: false)
        UserDefaults.standard.set(true, forKey: key)
        #expect(SettingsExperimentsViewController.enabledCount(sessionThreadsEnabled: false) == without + 1)
    }

    /// Switches the user can see: a collection view keeps removed cells hidden in its reuse pool.
    private static func switches(in view: UIView) -> [UISwitch] {
        guard !view.isHidden else { return [] }
        return (view as? UISwitch).map { [$0] } ?? view.subviews.flatMap(switches(in:))
    }
}
