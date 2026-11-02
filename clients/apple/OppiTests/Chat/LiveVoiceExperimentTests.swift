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
        let (connection, _) = await makeTestConnection(sessionId: "live-voice-entry")
        let chat = ChatViewController(
            sessionId: "live-voice-entry",
            connection: connection,
            navigation: AppNavigation()
        )
        // The app root holds the app's Live Voice call, which decides whether one may start.
        chat.traitOverrides.appRootEnvironment = makeTestAppRoot()

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
        let (root, routes) = try await makeQuickSessionRoot(liveVoice: true)
        defer { routes.end() }
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
        let (root, routes) = try await makeQuickSessionRoot(liveVoice: true, composerDraftStore: store)
        defer { routes.end() }
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
        let (root, routes) = try await makeQuickSessionRoot(liveVoice: true)
        defer { routes.end() }
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
    ) async throws -> (root: AppRootEnvironment, routes: TestURLProtocol.RouteScope) {
        // The server's own work is not what these tests are about: it answers as an
        // unreachable server does, and a route it did not plan fails the test.
        let routes = TestURLProtocol.routeScope(mockPageRoutes { _ in nil })
        let ready = try await makeTestAppRoot(
            readyServerId: "sha256:live-voice-\(UUID().uuidString)",
            apiClient: makeTestURLProtocolClient(host: "live-voice-experiment.test")
        )
        let connection = try #require(ready.coordinator.activeConnection)
        connection.setSplitStreamCapabilitiesForTesting(liveVoice: liveVoice)
        // A cold launch waits for the workspace list; this server has loaded its (empty) one.
        connection.workspaceStore.isLoaded = true
        guard let composerDraftStore else { return (ready, routes) }
        return (makeTestAppRoot(coordinator: ready.coordinator, composerDraftStore: composerDraftStore), routes)
    }
}

/// The Experiments page: its toggle writes the setting it names, and the root
/// count includes Live Voice.
@Suite("Settings Experiments page", .serialized)
@MainActor
struct SettingsExperimentsPageTests {
    @Test("The Live Voice toggle saves its experiment")
    func togglesSaveTheirExperiments() async throws {
        let defaults = try #require(UserDefaults(suiteName: "SettingsExperimentsPageTests-\(UUID().uuidString)"))
        let page = SettingsExperimentsViewController(defaults: defaults)
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

        let liveVoice = try #require(await toggle("settings.experiments.liveVoice"))
        #expect(!liveVoice.isOn)
        flip(liveVoice)
        #expect(defaults.bool(forKey: AppPreferences.Experiments.liveVoiceKey))
    }

    @Test("The root count includes Live Voice")
    func enabledCountIncludesLiveVoice() {
        let key = AppPreferences.Experiments.liveVoiceKey
        let before = UserDefaults.standard.object(forKey: key)
        defer {
            if let before { UserDefaults.standard.set(before, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.set(false, forKey: key)
        let without = SettingsExperimentsViewController.enabledCount()
        UserDefaults.standard.set(true, forKey: key)
        #expect(SettingsExperimentsViewController.enabledCount() == without + 1)
    }

    /// Switches the user can see: a collection view keeps removed cells hidden in its reuse pool.
    private static func switches(in view: UIView) -> [UISwitch] {
        guard !view.isHidden else { return [] }
        return (view as? UISwitch).map { [$0] } ?? view.subviews.flatMap(switches(in:))
    }
}
