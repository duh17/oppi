import XCTest

/// The `example-shelf` plugin against the real server on the scripted faux model: a durable chat
/// in a workspace that holds a Godot game writes a picture, a PDF, and notes and starts a
/// subagent, all in one codemode call. With the plugin on, the **Shelf** pill opens a pane of
/// tiles (full screen on an iPhone), and the PDF's tile opens the file in that same pane, filling
/// it, with Back to the tiles: no new pane on an iPad.
///
/// Run with `e2e.sh --native --durable --faux-model` (iPad: `OPPI_SIM_DEVICE_PROFILE=ipad`);
/// skipped otherwise.
@MainActor
final class ExtensionShelfE2ETests: E2ETestCase {
    private static let pill = "extension-strip-aboveEditor-pill-surface-example_2dshelf"
    private static let tilePrefix = "extension.surface.example_2dshelf.shelf."

    /// Typed into the composer as one line; the faux model turns each `\n` into a line break.
    /// Every byte the files hold is below 0x80, so `write` stores them as they are: a 64 × 48
    /// BMP, a one-page PDF with its cross-reference table, and Markdown.
    private static let script = [
        "const nl = String.fromCharCode(10);",
        "const le = (n) => [n % 256, (n >> 8) % 256, (n >> 16) % 256, (n >> 24) % 256];",
        "const w = 64, h = 48, size = w * 3 * h;",
        "const bmp = [66, 77, ...le(54 + size), 0, 0, 0, 0, ...le(54), ...le(40), ...le(w), ...le(h), 1, 0, 24, 0, ...le(0), ...le(size), ...le(0), ...le(0), ...le(0), ...le(0)];",
        "for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) bmp.push(60 + y, 30 + x, 90 - y);",
        #"const text = "BT /F1 28 Tf 72 700 Td (Shelf report) Tj 0 -40 Td /F1 16 Tf (Written by the chat) Tj ET";"#,
        #"const objs = ["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>", "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>", "<< /Length " + text.length + " >>" + nl + "stream" + nl + text + nl + "endstream", "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"];"#,
        #"let pdf = "%PDF-1.4" + nl; const offsets = [];"#,
        #"objs.forEach((o, i) => { offsets.push(pdf.length); pdf += (i + 1) + " 0 obj" + nl + o + nl + "endobj" + nl; });"#,
        "const xref = pdf.length;",
        #"pdf += "xref" + nl + "0 6" + nl + "0000000000 65535 f " + nl + offsets.map((o) => String(o).padStart(10, "0") + " 00000 n " + nl).join("") + "trailer" + nl + "<< /Size 6 /Root 1 0 R >>" + nl + "startxref" + nl + xref + nl + "%%EOF";"#,
        ##"await tools.write({ path: "notes/plan.md", content: "# Shelf plan" + nl + nl + "- Read the report" + nl + "- Check the sky" + nl });"##,
        #"await tools.write({ path: "out/report.pdf", content: pdf });"#,
        #"await tools.write({ path: "art/sky.bmp", content: bmp.map((c) => String.fromCharCode(c)).join("") });"#,
        #"await tools.subagent({ action: "spawn", name: "reviewer", task: "Read out/report.pdf and say what it covers" });"#,
        #"return "3 files and a reviewer";"#,
    ].joined(separator: #"\n"#)

    nonisolated(unsafe) private var shelfExtensionId: String?

    override var e2eAutoCreatesSessionOnLaunch: Bool { false }

    override func configureE2ELaunch(_ application: XCUIApplication) {
        application.launchArguments += [
            "-dev.chenda.Oppi.theme.mode", "manual",
            "-dev.chenda.Oppi.theme.id", "dark",
        ]
        application.launchArguments += OppiTestLaunch.experimentArguments([.godotPane: true])
    }

    override func tearDownWithError() throws {
        // The plugin outlives a case on the shared server; leave it off, as it ships.
        if let id = shelfExtensionId {
            _ = try? e2eLabAPIJSON(method: "PUT", path: "/server/resources/extensions/\(id)/enabled", body: ["enabled": false])
        }
        try super.tearDownWithError()
    }

    func testShelfPillOpensItsTilesAndATileOpensTheFile() throws {
        guard E2ELabServerContext.durableSessions else {
            throw XCTSkip("Needs e2e.sh --native --durable --faux-model")
        }

        // A workspace holding Sword Lab, and the shelf turned on before the chat starts.
        let game = try createLabWorkspaceFileFixture(
            directoryName: "sword-lab",
            filename: "project.godot",
            base64: Data("config_version=5\n\n[application]\n\nconfig/name=\"Sword Lab\"\n".utf8).base64EncodedString()
        )
        let workspaceId = try createLabWorkspace(
            named: "Shelf Lab", hostMount: game.hostMount
        )
        try enableShelf()
        let session = try e2eLabAPIJSON(
            method: "POST", path: "/workspaces/\(workspaceId)/sessions",
            body: ["name": "Shelf demo", "engine": "durable"]
        )
        let sessionId = try XCTUnwrap((session["session"] as? [String: Any])?["id"] as? String)
        openSessionDeepLink(id: sessionId)
        waitForAckedSubscription(sessionId: sessionId, level: "full")

        sendMessage("faux:codemode \(Self.script)")
        // The faux model streams the script at four tokens a second, so the call takes minutes. The
        // shelf is drawn after its tool round, while the reply still streams: three files, the
        // subagent, and the game.
        let pill = app.descendants(matching: .any)[Self.pill]
        XCTAssertTrue(pill.waitForExistence(timeout: 360), "The shelf pill did not appear")
        let counted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS 'Shelf · 5'"), object: pill)
        XCTAssertEqual(XCTWaiter.wait(for: [counted], timeout: 30), .completed, "Pill reads \(String(describing: pill.value))")
        try saveLabScreenshot(name: "shelf-1-pill")

        tap(pill, named: "Shelf pill")
        let report = tile(labelContaining: "report.pdf")
        XCTAssertTrue(report.waitForExistence(timeout: 15), "The shelf's PDF tile did not show")
        // The previews arrive after the tiles: the PDF's page count, the picture's size.
        let read = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS 'PDF · 1 page'"), object: report)
        XCTAssertEqual(XCTWaiter.wait(for: [read], timeout: 20), .completed, "PDF tile reads \(report.label)")
        // The picture, the notes, the game, and the subagent, by the words their tiles read.
        for words in ["sky", "plan", "Sword Lab", "reviewer"] {
            XCTAssertTrue(tile(labelContaining: words).exists, "No tile reads \(words)")
        }
        try saveLabScreenshot(name: "shelf-2-tiles")

        let panel = app.descendants(matching: .any)["extensionPanel.example-shelf"]
        XCTAssertTrue(panel.exists, "The shelf is a panel pane")
        let paneFrame = panel.frame
        let grips = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'pane.grip.'"))
        let gripCount = grips.count
        tap(report, named: "PDF tile")
        let pdf = app.descendants(matching: .any)["fileViewer.pdf"]
        XCTAssertTrue(pdf.waitForExistence(timeout: 20), "The PDF did not open")
        let fills = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            abs(pdf.frame.minX - paneFrame.minX) < 4 && abs(pdf.frame.width - paneFrame.width) < 4
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [fills], timeout: 10), .completed,
                       "The PDF fills the shelf's pane: file \(pdf.frame), pane \(paneFrame)")
        XCTAssertEqual(grips.count, gripCount, "The PDF opened in the shelf's pane, not a new one")
        // The pane's own Back, in its bar above the PDF (a chat beside has its own).
        let back = try XCTUnwrap(
            app.navigationBars.buttons.matching(identifier: "BackButton").allElementsBoundByIndex.first {
                paneFrame.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY))
            },
            "The PDF has the pane's Back"
        )
        try saveLabScreenshot(name: "shelf-3-file-open")

        tap(back, named: "PDF Back")
        XCTAssertTrue(report.waitForExistence(timeout: 10), "Back returns to the shelf's tiles")
        XCTAssertFalse(pdf.exists, "Back closed the PDF")
        try saveLabScreenshot(name: "shelf-4-back")
    }

    private func tile(labelContaining text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@", Self.tilePrefix, text
        )).firstMatch
    }

    private func enableShelf() throws {
        let listed = try e2eLabAPIJSON(method: "GET", path: "/server/resources/extensions?plugins=true")
        let rows = try XCTUnwrap(listed["extensions"] as? [[String: Any]])
        let row = try XCTUnwrap(rows.first { $0["name"] as? String == "oppi-example-shelf" }, "No example-shelf row")
        let id = try XCTUnwrap(row["id"] as? String)
        shelfExtensionId = id
        _ = try e2eLabAPIJSON(method: "PUT", path: "/server/resources/extensions/\(id)/enabled", body: ["enabled": true])
    }
}
