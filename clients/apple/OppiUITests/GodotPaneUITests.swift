import XCTest

/// The Godot pane in the production shell over the chat-routes fixtures
/// (`SCREENSHOT_SCREEN=pane-restore`) on the iPad mini, with the Godot Pane
/// experiment on. The fixture server lists one Godot project per state a pane
/// shows (`ChatRoutesGodot`); their builds are the sample's export in
/// `OppiTests/Fixtures/godot-sample.pck`, and its player link is scripted in
/// process. A build of the app made without the engine offers no Godot, and
/// these tests skip there.
///
/// Captures go to the result bundle and, with `OPPI_GODOT_PANE_SHOTS` set, to
/// that folder upright at 1400 px at most, named with `OPPI_GODOT_PANE_SHOTS_SUFFIX`.
/// `OPPI_GODOT_PANE_SHOTS_SCHEME` picks the theme and `OPPI_GODOT_PANE_CONTENT_SIZE`
/// the Dynamic Type size. `OPPI_GODOT_PANE_GAMES` (`Name=/path/to/game.pck;…`)
/// lists real games first (the harness's `CHAT_ROUTES_GODOT_GAMES`), and the
/// switching test plays the first two.
@MainActor
final class GodotPaneUITests: XCTestCase, PreviewUITestCase {
    var app: XCUIApplication!

    private let sessionRow = "session.nav.chat-routes-session"
    private let tideRunner = "godot.projects.row.tide-runner-3fa9c2b1"
    private let mossGarden = "godot.projects.row.moss-garden-7c1d2e3f"
    private let starCourier = "godot.projects.row.star-courier-9b2e4a10"
    private let pocketDungeon = "godot.projects.row.pocket-dungeon-51d0c7e2"
    private let lantern = "godot.projects.row.lantern-6e8a1f33"

    override func setUpWithError() throws {
#if !targetEnvironment(simulator)
        throw XCTSkip("Pane tests are simulator-only")
#endif
        continueAfterFailure = false
        addTeardownBlock { @MainActor in XCUIDevice.shared.orientation = .portrait }
    }

    /// The launcher offers Godot, which lists every project the server found,
    /// with a build's label or "No build yet".
    func testTheLauncherListsTheServersGames() throws {
        try openChat(orientation: .landscapeLeft)
        try openGodotList(capturingLauncher: true)
        for row in [tideRunner, mossGarden, starCourier, pocketDungeon, lantern] {
            XCTAssertTrue(app.cells[row].waitUntilExists(timeout: 10), "\(row) is listed")
        }
        capture("projects")
    }

    /// A server with no Godot projects says where they come from.
    func testAServerWithNoGamesSaysSo() throws {
        try openChat(orientation: .landscapeLeft, projects: "empty")
        try openGodotList()
        let state = app.descendants(matching: .any)["godot.projects.state"]
        XCTAssertTrue(state.waitUntilExists(timeout: 10))
        XCTAssertTrue(waitFor((state.value as? String) == "empty"), "No projects (value: \(state.value ?? "nil"))")
        capture("projects-empty")
    }

    /// The sample starts beside the chat, a tap lands in the game, the bar
    /// pauses and resumes it, and it keeps drawing full width and at a third.
    func testTheLauncherPlaysTheSampleBesideTheChat() throws {
        try openChat(orientation: .landscapeLeft)
        try open(tideRunner)
        let surface = app.descendants(matching: .any)["godot.surface"]
        let composer = app.descendants(matching: .any)["chat.input"]
        XCTAssertTrue(composer.isHittable, "The chat stays beside the game")
        XCTAssertLessThanOrEqual(composer.frame.maxX, surface.frame.minX + 1, "The game sits after the chat")
        hold(for: 1.5)
        capture("running-half")

        // Taps add a ball where they land and count in the game's label.
        for point in [CGVector(dx: 0.3, dy: 0.4), CGVector(dx: 0.7, dy: 0.6), CGVector(dx: 0.5, dy: 0.8)] {
            surface.coordinate(withNormalizedOffset: point).tap()
        }
        hold(for: 0.5)
        capture("running-after-taps")

        let play = app.buttons["godot.play"]
        play.tap()
        XCTAssertTrue(waitFor((play.value as? String) == "paused"), "Pause paused the game")
        let resume = app.buttons["godot.resume"]
        XCTAssertTrue(resume.waitUntilExists(timeout: 5), "The paused game dims under a Play button")
        capture("paused")
        resume.tap()
        XCTAssertTrue(waitFor((play.value as? String) == "running"), "Play over the game resumed it")
        XCTAssertTrue(waitFor(!resume.exists), "The dim lifts")

        // The game's pane zoomed to the whole window from its grip's menu, then back.
        let grips = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'pane.grip.'"))
        grips.matching(NSPredicate(format: "label ENDSWITH '2 of 2'")).firstMatch.tap()
        let zoom = app.buttons["pane.menu.zoom"]
        XCTAssertTrue(zoom.waitUntilExists(timeout: 5), "The Godot pane's grip opens its menu")
        zoom.tap()
        XCTAssertTrue(waitFor(!composer.isHittable), "The game's pane fills the window")
        XCTAssertEqual(play.value as? String, "running", "The game runs on, full width")
        hold(for: 1)
        capture("running-full")
        grips.matching(NSPredicate(format: "value == 'Zoomed'")).firstMatch.tap()
        XCTAssertTrue(zoom.waitUntilExists(timeout: 5), "The zoomed grip opens its menu")
        zoom.tap()
        XCTAssertTrue(waitFor(composer.isHittable), "Restore brought the chat back")

        // A third pane beside the game: it draws at a third of the window.
        app.typeKey("d", modifierFlags: .command)
        XCTAssertTrue(app.descendants(matching: .any)["pane.launcher"].waitUntilExists(timeout: 5))
        hold(for: 1.5)
        XCTAssertEqual(play.value as? String, "running", "The game runs in its narrower pane")
        capture("running-third")
    }

    /// A project with no exported pack says so.
    func testAProjectWithNoBuildSaysSo() throws {
        try openChat(orientation: .landscapeLeft)
        try openGodotList()
        let row = app.cells[mossGarden]
        XCTAssertTrue(row.waitUntilExists(timeout: 10), "The project is listed")
        row.tap()
        let state = app.descendants(matching: .any)["godot.state"]
        XCTAssertTrue(state.waitUntilExists(timeout: 10), "The pane shows its state")
        XCTAssertTrue(waitFor((state.value as? String) == "noBuild"), "No build yet (value: \(state.value ?? "nil"))")
        capture("no-build")
    }

    /// An error the game's own script raises shows over the game with its
    /// file and line. Star Courier runs the sandbox probe, whose last error is
    /// the engine refusing to list through a link out of `user://` that the
    /// harness planted before the game started (`ChatRoutesGodot`): files
    /// are checked by where they really are, not by their path's text.
    func testAGameErrorShowsItsFileAndLine() throws {
        try openChat(orientation: .landscapeLeft)
        try open(starCourier)
        let overlay = app.descendants(matching: .any)["godot.error"]
        XCTAssertTrue(overlay.waitUntilExists(timeout: 15), "The script's error shows over the game")
        let message = app.staticTexts["godot.error.message"]
        XCTAssertTrue(
            waitFor(message.label.contains("Sandbox refused folder access: user://escape/Library")),
            "The planted link leads nowhere (message: \(message.label))"
        )
        let location = app.staticTexts["godot.error.location"]
        XCTAssertTrue(location.waitUntilExists(timeout: 5))
        XCTAssertTrue(location.label.hasPrefix("res://probe.gd"), "It names the game's own file (\(location.label))")
        let dismiss = app.buttons["godot.error.dismiss"]
        XCTAssertGreaterThanOrEqual(min(dismiss.frame.width, dismiss.frame.height), 44, "Dismiss is a full touch target")
        hold(for: 1)
        capture("error-overlay")
        // At a third of the window the long backtrace scrolls inside the card.
        app.typeKey("d", modifierFlags: .command)
        XCTAssertTrue(app.descendants(matching: .any)["pane.launcher"].waitUntilExists(timeout: 5))
        hold(for: 1.5)
        let pane = app.descendants(matching: .any)["godot.pane"]
        XCTAssertLessThanOrEqual(overlay.frame.height, pane.frame.height * 0.45, "The card keeps to its share of the pane")
        capture("error-overlay-third")
        dismiss.tap()
        XCTAssertTrue(waitFor(!overlay.exists), "Dismiss hides it")
    }

    /// Ask Agent on a game's error leaves a draft in the composer of the chat
    /// beside it: the game, the error with its file and line, and the current
    /// frame attached, unsent. The game is Star Courier's script error, or
    /// the first of `OPPI_GODOT_PANE_GAMES` (a game with a broken script).
    func testAskAgentLeavesTheErrorAndTheFrameInTheChatsComposer() throws {
        try openChat(orientation: .landscapeLeft)
        try open(errorGame)
        let overlay = app.descendants(matching: .any)["godot.error"]
        XCTAssertTrue(overlay.waitUntilExists(timeout: 15), "The script's error shows over the game")
        let location = app.staticTexts["godot.error.location"]
        XCTAssertTrue(location.waitUntilExists(timeout: 5))
        let ask = app.buttons["godot.error.askAgent"]
        XCTAssertTrue(ask.waitUntilExists(timeout: 5), "A chat is beside the game, so Ask Agent shows")
        XCTAssertGreaterThanOrEqual(ask.frame.height, 44, "Ask Agent is a full touch target")
        hold(for: 1.5)
        capture("ask-agent-overlay")
        ask.tap()

        let input = app.textViews["chat.input"]
        let fileLine = location.label
        XCTAssertTrue(
            waitFor(((input.value as? String) ?? "").contains("shows this error:")),
            "The draft is in the composer (value: \(input.value ?? "nil"))"
        )
        let draft = (input.value as? String) ?? ""
        XCTAssertTrue(draft.contains(fileLine), "The draft names the error's file and line \(fileLine): \(draft)")
        XCTAssertTrue(composerImage().waitUntilExists(timeout: 5), "The frame is attached")
        hold(for: 1.5)
        XCTAssertEqual(input.value as? String, draft, "Nothing was sent")
        capture("ask-agent-draft")
    }

    /// The bar's Snapshot to Chat leaves the game's state and the current
    /// frame in the chat's composer: the game and release, the scene the
    /// engine plays, playing or paused, and its recent log.
    func testSnapshotToChatLeavesTheGamesStateAndFrameInTheComposer() throws {
        try openChat(orientation: .landscapeLeft)
        try open(tideRunner)
        hold(for: 1.5)
        let snapshot = app.buttons["godot.snapshot"]
        XCTAssertTrue(snapshot.waitUntilExists(timeout: 5), "The bar offers Snapshot to Chat")
        XCTAssertEqual(snapshot.label, "Snapshot to Chat")
        capture("snapshot-bar")
        snapshot.tap()
        let input = app.textViews["chat.input"]
        XCTAssertTrue(
            waitFor(((input.value as? String) ?? "").hasPrefix("A snapshot of the Godot game “Tide Runner” (release 1):")),
            "The draft names the game and release (value: \(input.value ?? "nil"))"
        )
        let draft = (input.value as? String) ?? ""
        // The engine's own startup prints outnumber the few a snapshot keeps.
        for line in ["- Scene: res://main.tscn", "- State: playing", "- View: ", "\nRecent log:\n- "] {
            XCTAssertTrue(draft.contains(line), "The snapshot has \(line): \(draft)")
        }
        XCTAssertTrue(composerImage().waitUntilExists(timeout: 5), "The frame is attached")
        hold(for: 1)
        capture("snapshot-draft")
    }

    /// A pack exported by a newer Godot is refused before the engine reads it.
    func testANewerExportIsRefused() throws {
        try openChat(orientation: .landscapeLeft)
        try openGodotList()
        app.cells[pocketDungeon].tap()
        let state = app.descendants(matching: .any)["godot.state"]
        XCTAssertTrue(state.waitUntilExists(timeout: 10))
        XCTAssertTrue(waitFor((state.value as? String) == "refused", timeout: 15), "value: \(state.value ?? "nil")")
        capture("refused")
    }

    /// A build that is still downloading shows that it is.
    func testABuildStillDownloadingSaysSo() throws {
        try openChat(orientation: .landscapeLeft)
        try openGodotList()
        app.cells[lantern].tap()
        let state = app.descendants(matching: .any)["godot.state"]
        XCTAssertTrue(state.waitUntilExists(timeout: 10))
        XCTAssertTrue(waitFor((state.value as? String) == "loading"), "value: \(state.value ?? "nil")")
        hold(for: 1)
        capture("loading")
    }

    /// A new build that changes project settings arrives while the game runs:
    /// the engine starts again on it in the same pane, with no relaunch.
    func testABuildThatChangesSettingsStartsTheGameAgain() throws {
        try openChat(orientation: .landscapeLeft, settingsBuild: true)
        try open(tideRunner)
        let pane = app.descendants(matching: .any)["godot.pane"]
        let play = app.buttons["godot.play"]
        XCTAssertEqual(pane.value as? String, "release 1")
        // The scripted server sends the settings build three seconds in.
        XCTAssertTrue(
            waitFor((pane.value as? String) == "release 2" && (play.value as? String) == "running", timeout: 30),
            "The settings build plays (pane: \(pane.value ?? "nil"), play: \(play.value ?? "nil"))"
        )
        XCTAssertFalse(app.descendants(matching: .any)["godot.notice"].exists, "Nothing asks for a relaunch")
        hold(for: 1)
        capture("settings-restarted")
    }

    /// A pane opened on another game ends the game playing and starts its
    /// own there; the first game's pane offers Play, which switches back.
    func testOpeningAnotherGameSwitchesToIt() throws {
        try openChat(orientation: .landscapeLeft)
        let (first, second) = switchingGames
        try open(first)
        hold(for: 1.5)
        capture("switch-first")

        try openGodotList()
        let row = app.cells[second]
        XCTAssertTrue(row.waitUntilExists(timeout: 10), "\(second) is listed")
        row.tap()
        XCTAssertTrue(waitFor(playValues() == ["ready", "running"], timeout: 30), "The second game took the engine (\(playValues()))")
        XCTAssertTrue(surfaceIsIn(pane: 1), "The game draws in the second game's pane")
        let state = app.descendants(matching: .any)["godot.state"]
        XCTAssertTrue(state.waitUntilExists(timeout: 5), "The first game's pane says it is ready")
        XCTAssertFalse(app.staticTexts["Relaunch Oppi to Play"].exists)
        hold(for: 1.5)
        capture("switch-second")

        state.buttons["Play"].tap()
        XCTAssertTrue(waitFor(playValues() == ["running", "ready"], timeout: 30), "Play switched back (\(playValues()))")
        XCTAssertTrue(surfaceIsIn(pane: 0), "The game draws in the first game's pane again")
        hold(for: 1.5)
        capture("switch-back")
    }

    /// A critically hot device pauses the game: the notice row says why, the
    /// game dims under a thermometer, and Play waits for it to cool.
    func testAHotDevicePausesTheGameAndSaysWhy() throws {
        try openChat(orientation: .landscapeLeft, hot: true)
        try open(tideRunner)
        let notice = app.descendants(matching: .any)["godot.notice"]
        XCTAssertTrue(notice.waitUntilExists(timeout: 15), "The heat notice shows")
        let play = app.buttons["godot.play"]
        XCTAssertEqual(play.value as? String, "paused", "The heat paused the game")
        XCTAssertFalse(play.isEnabled, "Play waits for the device to cool")
        let reason = app.descendants(matching: .any)["godot.pauseCover.reason"]
        XCTAssertTrue(reason.waitUntilExists(timeout: 5), "The dimmed game shows why")
        XCTAssertEqual(reason.label, "Too hot to play")
        hold(for: 1)
        capture("too-hot")
    }

    /// A Godot pane a relaunch restored waits for Play, then plays.
    func testARestoredGameWaitsForPlay() throws {
        try openChat(orientation: .landscapeLeft, seed: "godot")
        let state = app.descendants(matching: .any)["godot.state"]
        XCTAssertTrue(state.waitUntilExists(timeout: 15))
        XCTAssertTrue(waitFor((state.value as? String) == "ready"), "value: \(state.value ?? "nil")")
        XCTAssertFalse(app.buttons["godot.play"].isEnabled, "The state's Play is the one action")
        hold(for: 1)
        capture("waiting")
        state.buttons["Play"].tap()
        XCTAssertTrue(waitFor((app.buttons["godot.play"].value as? String) == "running", timeout: 30), "Play started the game")
    }

    /// A second pane on the playing game shows Play Here; Play Here moves the
    /// game there, and the first pane keeps the frame it had.
    func testASecondPaneOnTheGameOffersPlayHere() throws {
        try openChat(orientation: .landscapeLeft)
        try open(tideRunner)
        hold(for: 1)
        let surface = app.descendants(matching: .any)["godot.surface"]
        let playingAt = surface.frame.minX
        app.typeKey("d", modifierFlags: .command)
        app.buttons["pane.launcher.godot"].tap()
        let row = app.cells[tideRunner]
        XCTAssertTrue(row.waitUntilExists(timeout: 10))
        row.tap()
        let state = app.descendants(matching: .any)["godot.state"]
        XCTAssertTrue(state.waitUntilExists(timeout: 10))
        XCTAssertTrue(waitFor((state.value as? String) == "elsewhere"), "value: \(state.value ?? "nil")")
        // The scripted server sends this second pane an agent's `run` a second in.
        hold(for: 2.5)
        XCTAssertEqual(state.value as? String, "elsewhere", "An agent's run left the game in its pane")
        XCTAssertLessThanOrEqual(surface.frame.maxX, state.frame.minX + 1, "The game still plays in the first pane")
        capture("elsewhere")
        app.buttons["Play Here"].tap()
        XCTAssertTrue(waitFor(surface.frame.minX > playingAt + 100), "The game moved to the new pane")
        XCTAssertTrue(waitFor((state.value as? String) == "elsewhere"), "The first pane offers Play Here now")
        hold(for: 1)
        capture("play-here-moved")
    }

    /// Settings › Experiments offers Godot Pane.
    func testExperimentsOfferGodotPane() throws {
        launchPreview(
            screen: "settings-sweep",
            environment: ["SCREENSHOT_SWEEP_PAGE": "experiments"],
            colorScheme: ProcessInfo.processInfo.environment["OPPI_GODOT_PANE_SHOTS_SCHEME"],
            arguments: launchArguments(godotPane: false),
            ready: nil
        )
        let toggle = app.descendants(matching: .any)["settings.experiments.godotPane"]
        XCTAssertTrue(toggle.waitUntilExists(timeout: 10), "The Godot Pane switch is listed")
        capture("settings-experiments")
    }

    // MARK: Steps

    private func openChat(
        orientation: UIDeviceOrientation, projects: String = "1", settingsBuild: Bool = false, hot: Bool = false, seed: String? = nil
    ) throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("Godot panes need a wide window; the iPad mini is the wide simulator")
        }
        XCUIDevice.shared.orientation = orientation
        var environment = ["CHAT_ROUTES_GODOT": projects, "CHAT_ROUTES_GODOT_PACK": try pack("godot-sample").base64EncodedString()]
        if settingsBuild {
            environment["CHAT_ROUTES_GODOT_PACK_SETTINGS"] = try pack("godot-sample-settings").base64EncodedString()
        }
        if hot { environment["CHAT_ROUTES_GODOT_HOT"] = "1" }
        if let games = ProcessInfo.processInfo.environment["OPPI_GODOT_PANE_GAMES"] { environment["CHAT_ROUTES_GODOT_GAMES"] = games }
        if let seed { environment["PANE_RESTORE_SEED"] = seed }
        launchPreview(
            screen: "pane-restore",
            environment: environment,
            colorScheme: ProcessInfo.processInfo.environment["OPPI_GODOT_PANE_SHOTS_SCHEME"],
            arguments: launchArguments(godotPane: true),
            ready: nil
        )
        let row = app.descendants(matching: .any)[sessionRow]
        XCTAssertTrue(row.waitUntilExists(timeout: 10), "The fixture session is listed")
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["chat.input"].waitUntilExists(timeout: 10), "The chat opened")
    }

    private func launchArguments(godotPane: Bool) -> [String] {
        var arguments = OppiTestLaunch.experimentArguments([.godotPane: godotPane])
        if let size = ProcessInfo.processInfo.environment["OPPI_GODOT_PANE_CONTENT_SIZE"], !size.isEmpty {
            arguments += ["-UIPreferredContentSizeCategoryName", size]
        }
        return arguments
    }

    /// Opens the launcher and its Godot choice. A build without the engine
    /// offers no Godot: the launcher is captured and the test skips.
    private func openGodotList(capturingLauncher: Bool = false) throws {
        app.typeKey("d", modifierFlags: .command)
        XCTAssertTrue(app.descendants(matching: .any)["pane.launcher"].waitUntilExists(timeout: 5), "⌘D opened the launcher")
        let godot = app.buttons["pane.launcher.godot"]
        guard godot.waitUntilExists(timeout: 3) else {
            capture("launcher-without-engine")
            throw XCTSkip("This build of the app has no game engine, so it offers no Godot")
        }
        XCTAssertEqual(godot.label.components(separatedBy: ",").first, "Godot", "The launcher names the choice Godot")
        if capturingLauncher {
            hold(for: 0.5)
            capture("launcher")
        }
        godot.tap()
    }

    /// Opens `row`'s game and waits for it to run.
    private func open(_ row: String) throws {
        try openGodotList()
        let cell = app.cells[row]
        XCTAssertTrue(cell.waitUntilExists(timeout: 10), "\(row) is listed")
        cell.tap()
        let play = app.buttons["godot.play"]
        XCTAssertTrue(play.waitUntilExists(timeout: 10), "The Godot pane opened with its bar")
        XCTAssertTrue(waitFor((play.value as? String) == "running", timeout: 30), "The game started (value: \(play.value ?? "nil"))")
        XCTAssertTrue(app.descendants(matching: .any)["godot.surface"].waitUntilExists(timeout: 5), "The game draws in the pane")
    }

    /// The game whose error Ask Agent hands off: the first of
    /// `OPPI_GODOT_PANE_GAMES`, by the harness's id, else Star Courier.
    private var errorGame: String {
        guard let name = (ProcessInfo.processInfo.environment["OPPI_GODOT_PANE_GAMES"] ?? "")
            .split(separator: ";").first?.split(separator: "=").first, !name.isEmpty else { return starCourier }
        return "godot.projects.row." + name.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: "-")
    }

    /// The composer's first image attachment.
    private func composerImage() -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat.attachment.image.")).firstMatch
    }

    /// The switching test's two rows: the first two of `OPPI_GODOT_PANE_GAMES`,
    /// by the harness's id (the name's slug), else Tide Runner and Star Courier.
    private var switchingGames: (String, String) {
        let names = (ProcessInfo.processInfo.environment["OPPI_GODOT_PANE_GAMES"] ?? "")
            .split(separator: ";").compactMap { $0.split(separator: "=").first.map(String.init) }
        guard names.count >= 2 else { return (tideRunner, starCourier) }
        func row(_ name: String) -> String {
            "godot.projects.row." + name.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: "-")
        }
        return (row(names[0]), row(names[1]))
    }

    /// Each Godot pane's Play value, leftmost pane first.
    private func playValues() -> [String] {
        app.buttons.matching(identifier: "godot.play").allElementsBoundByIndex
            .sorted { $0.frame.minX < $1.frame.minX }
            .map { ($0.value as? String) ?? "" }
    }

    /// Whether the game's view sits in the `index`th Godot pane from the left.
    private func surfaceIsIn(pane index: Int) -> Bool {
        let panes = app.descendants(matching: .any).matching(identifier: "godot.pane").allElementsBoundByIndex
            .sorted { $0.frame.minX < $1.frame.minX }
        let surface = app.descendants(matching: .any)["godot.surface"]
        guard panes.indices.contains(index), surface.exists else { return false }
        return panes[index].frame.contains(CGPoint(x: surface.frame.midX, y: surface.frame.midY))
    }

    private func pack(_ name: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: name, withExtension: "pck"),
            "\(name).pck is a resource of OppiUITests (project.yml)"
        )
        return try Data(contentsOf: url)
    }

    /// The screen's capture, attached; with `OPPI_GODOT_PANE_SHOTS` set, also
    /// written there upright, at most 1400 px on its long side.
    private func capture(_ name: String) {
        let environment = ProcessInfo.processInfo.environment
        let suffix = environment["OPPI_GODOT_PANE_SHOTS_SUFFIX"].map { "-\($0)" } ?? ""
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name + suffix
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let folder = environment["OPPI_GODOT_PANE_SHOTS"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let image = screenshot.image
        let pixels = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let factor = min(1, 1400 / max(pixels.width, pixels.height))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let size = CGSize(width: (pixels.width * factor).rounded(), height: (pixels.height * factor).rounded())
        // Drawing the image bakes its orientation into the pixels, so the PNG
        // is upright with no orientation tag.
        let png = UIGraphicsImageRenderer(size: size, format: format).pngData { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        try? png.write(to: URL(filePath: folder).appending(path: "\(name)\(suffix).png"))
    }
}
