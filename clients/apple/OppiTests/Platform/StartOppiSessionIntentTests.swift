import AppIntents
import Foundation
import Testing
@testable import Oppi

@Suite("IntentSessionRanking")
struct IntentSessionRankingTests {
    private struct Item: Equatable {
        let id: String
        let name: String
    }

    @Test func lastUsedEqualToDefaultRanksOnceThenByName() {
        let ranked = IntentSessionRanking.rank(
            [
                Item(id: "zeta", name: "Zeta"),
                Item(id: "alpha", name: "Alpha"),
                Item(id: "preferred", name: "Preferred"),
            ],
            id: \.id,
            name: \.name,
            lastUsedId: "preferred",
            defaultId: "preferred"
        )

        #expect(ranked.map(\.id) == ["preferred", "alpha", "zeta"])
    }

    @Test func staleIdsFallBackToNameOrder() {
        let ranked = IntentSessionRanking.rank(
            [
                Item(id: "beta", name: "Beta"),
                Item(id: "alpha", name: "Alpha"),
            ],
            id: \.id,
            name: \.name,
            lastUsedId: "gone-last",
            defaultId: "gone-default"
        )

        #expect(ranked.map(\.id) == ["alpha", "beta"])
    }

    @Test func onlyLastUsedIdIsSet() {
        let ranked = IntentSessionRanking.rank(
            [
                Item(id: "beta", name: "Beta"),
                Item(id: "alpha", name: "Alpha"),
                Item(id: "last", name: "Last"),
            ],
            id: \.id,
            name: \.name,
            lastUsedId: "last",
            defaultId: nil
        )

        #expect(ranked.map(\.id) == ["last", "alpha", "beta"])
    }

    @Test func onlyDefaultIdIsSet() {
        let ranked = IntentSessionRanking.rank(
            [
                Item(id: "beta", name: "Beta"),
                Item(id: "alpha", name: "Alpha"),
                Item(id: "default", name: "Default"),
            ],
            id: \.id,
            name: \.name,
            lastUsedId: nil,
            defaultId: "default"
        )

        #expect(ranked.map(\.id) == ["default", "alpha", "beta"])
    }

    @Test func lastUsedBeatsDefaultWhenBothArePresent() {
        let ranked = IntentSessionRanking.rank(
            [
                Item(id: "default", name: "Default"),
                Item(id: "last", name: "Last"),
                Item(id: "alpha", name: "Alpha"),
            ],
            id: \.id,
            name: \.name,
            lastUsedId: "last",
            defaultId: "default"
        )

        #expect(ranked.map(\.id) == ["last", "default", "alpha"])
    }

    @Test func staleLastUsedFallsBackToDefault() {
        let ranked = IntentSessionRanking.rank(
            [
                Item(id: "default", name: "Default"),
                Item(id: "alpha", name: "Alpha"),
            ],
            id: \.id,
            name: \.name,
            lastUsedId: "missing",
            defaultId: "default"
        )

        #expect(ranked.map(\.id) == ["default", "alpha"])
    }
}

@Suite("WorkspaceEntity identity")
struct WorkspaceEntityIdentityTests {
    @Test func compositeIdRoundTrips() {
        let encoded = WorkspaceEntityID.encode(serverId: "server-a", workspaceId: "ws-1")
        let decoded = WorkspaceEntityID.decode(encoded)

        #expect(decoded?.serverId == "server-a")
        #expect(decoded?.workspaceId == "ws-1")
    }

    @Test func sameWorkspaceIdOnTwoServersIsUnique() {
        let left = WorkspaceEntityID.encode(serverId: "server-a", workspaceId: "ws-shared")
        let right = WorkspaceEntityID.encode(serverId: "server-b", workspaceId: "ws-shared")

        #expect(left != right)
        #expect(WorkspaceEntityID.decode(left)?.serverId == "server-a")
        #expect(WorkspaceEntityID.decode(right)?.serverId == "server-b")
    }

    @Test func entityIdUsesCompositeIdentity() {
        let entity = WorkspaceEntity(
            serverId: "server-a",
            workspaceId: "ws-1",
            name: "Oppi",
            serverName: "Studio",
            showsServerSubtitle: true
        )

        #expect(entity.id == WorkspaceEntityID.encode(serverId: "server-a", workspaceId: "ws-1"))
        #expect(entity.displayRepresentation.subtitle != nil)
    }

    @Test func plainWorkspaceIdDoesNotDecodeAsComposite() {
        #expect(WorkspaceEntityID.decode("ws-1") == nil)
    }
}

@Suite("IntentSessionDisambiguation")
struct IntentSessionDisambiguationTests {
    private let studio = IntentSessionDisambiguation.ServerHit(serverId: "studio", serverName: "Studio")
    private let laptop = IntentSessionDisambiguation.ServerHit(serverId: "laptop", serverName: "Laptop")

    private let studioCatalog = IntentSessionDisambiguation.Catalog(
        serverId: "studio",
        serverName: "Studio",
        workspaces: [
            .init(id: "ws-oppi", name: "Oppi"),
            .init(id: "ws-blog", name: "Blog"),
        ]
    )

    private let laptopCatalog = IntentSessionDisambiguation.Catalog(
        serverId: "laptop",
        serverName: "Laptop",
        workspaces: [
            .init(id: "ws-oppi-laptop", name: "Oppi"),
            .init(id: "ws-notes", name: "Notes"),
        ]
    )

    @Test func oneServerSkipsServerAsk() {
        let decision = IntentSessionDisambiguation.decide(
            pairedServers: [studio],
            catalogs: [studioCatalog],
            namedWorkspace: nil,
            selectedServerId: nil,
            selectedWorkspace: nil
        )

        guard case .askWorkspace(let hits, let includeServerSubtitle) = decision else {
            Issue.record("Expected workspace ask, got \(decision)")
            return
        }
        #expect(hits.map(\.workspaceId) == ["ws-oppi", "ws-blog"])
        #expect(includeServerSubtitle == false)
    }

    @Test func oneServerWithSingleWorkspaceResolves() {
        let decision = IntentSessionDisambiguation.decide(
            pairedServers: [studio],
            catalogs: [
                IntentSessionDisambiguation.Catalog(
                    serverId: "studio",
                    serverName: "Studio",
                    workspaces: [.init(id: "ws-only", name: "Only")]
                ),
            ],
            namedWorkspace: nil,
            selectedServerId: nil,
            selectedWorkspace: nil
        )

        #expect(
            decision == .resolved(
                IntentSessionDisambiguation.WorkspaceHit(
                    serverId: "studio",
                    serverName: "Studio",
                    workspaceId: "ws-only",
                    workspaceName: "Only"
                )
            )
        )
    }

    @Test func uniqueNameAcrossServersSkipsServerAsk() {
        let decision = IntentSessionDisambiguation.decide(
            pairedServers: [studio, laptop],
            catalogs: [studioCatalog, laptopCatalog],
            namedWorkspace: "Blog",
            selectedServerId: nil,
            selectedWorkspace: nil
        )

        #expect(
            decision == .resolved(
                IntentSessionDisambiguation.WorkspaceHit(
                    serverId: "studio",
                    serverName: "Studio",
                    workspaceId: "ws-blog",
                    workspaceName: "Blog"
                )
            )
        )
    }

    @Test func duplicateNamesAskWorkspaceWithServerSubtitle() {
        let decision = IntentSessionDisambiguation.decide(
            pairedServers: [studio, laptop],
            catalogs: [studioCatalog, laptopCatalog],
            namedWorkspace: "Oppi",
            selectedServerId: nil,
            selectedWorkspace: nil
        )

        guard case .askWorkspace(let hits, let includeServerSubtitle) = decision else {
            Issue.record("Expected workspace ask, got \(decision)")
            return
        }
        #expect(Set(hits.map(\.serverId)) == ["studio", "laptop"])
        #expect(includeServerSubtitle)
    }

    @Test func unnamedWithTwoServersAsksServerFirst() {
        let decision = IntentSessionDisambiguation.decide(
            pairedServers: [studio, laptop],
            catalogs: [studioCatalog, laptopCatalog],
            namedWorkspace: nil,
            selectedServerId: nil,
            selectedWorkspace: nil
        )

        guard case .askServer(let servers) = decision else {
            Issue.record("Expected server ask, got \(decision)")
            return
        }
        #expect(servers.map(\.serverId) == ["studio", "laptop"])
    }
}

@Suite("IntentSessionOpenTrigger")
@MainActor
struct IntentSessionOpenTriggerTests {
    @Test func consumeOnce() {
        let fixture = Fixture()
        defer { fixture.remove() }
        let trigger = fixture.makeTrigger()
        let requestID = trigger.issueRequestID()
        trigger.enqueue(fixture.receipt(requestID: requestID, sessionId: "session-1"))

        let first = trigger.consume(startupComplete: true)
        let second = trigger.consume(startupComplete: true)

        #expect(first?.sessionId == "session-1")
        #expect(second == nil)
    }

    @Test func newerWins() {
        let fixture = Fixture()
        defer { fixture.remove() }
        let trigger = fixture.makeTrigger()
        let firstID = trigger.issueRequestID()
        let secondID = trigger.issueRequestID()
        trigger.enqueue(fixture.receipt(requestID: firstID, sessionId: "older"))
        trigger.enqueue(fixture.receipt(requestID: secondID, sessionId: "newer"))

        #expect(trigger.consume(startupComplete: true)?.sessionId == "newer")
    }

    @Test func olderAsyncDoesNotOverrideNewer() {
        let fixture = Fixture()
        defer { fixture.remove() }
        let trigger = fixture.makeTrigger()
        let firstID = trigger.issueRequestID()
        let secondID = trigger.issueRequestID()
        trigger.enqueue(fixture.receipt(requestID: secondID, sessionId: "newer"))
        trigger.enqueue(fixture.receipt(requestID: firstID, sessionId: "older"))

        #expect(trigger.consume(startupComplete: true)?.sessionId == "newer")
    }

    @Test func consumeWaitsForStartupGate() {
        let fixture = Fixture()
        defer { fixture.remove() }
        let trigger = fixture.makeTrigger()
        let requestID = trigger.issueRequestID()
        trigger.enqueue(fixture.receipt(requestID: requestID, sessionId: "session-1"))

        #expect(trigger.consume(startupComplete: false) == nil)
        #expect(trigger.consume(startupComplete: true)?.sessionId == "session-1")
    }

    @Test func olderEnqueueAfterConsumeIsIgnored() {
        let fixture = Fixture()
        defer { fixture.remove() }
        let trigger = fixture.makeTrigger()
        let firstID = trigger.issueRequestID()
        let secondID = trigger.issueRequestID()
        trigger.enqueue(fixture.receipt(requestID: secondID, sessionId: "newer"))

        #expect(trigger.consume(startupComplete: true)?.sessionId == "newer")
        trigger.enqueue(fixture.receipt(requestID: firstID, sessionId: "older"))
        #expect(trigger.consume(startupComplete: true) == nil)
    }

    @Test func persistedReceiptSurvivesNewInstance() {
        let fixture = Fixture()
        defer { fixture.remove() }
        let first = fixture.makeTrigger()
        let requestID = first.issueRequestID()
        first.enqueue(
            fixture.receipt(
                requestID: requestID,
                sessionId: "session-1",
                unsentPrompt: "Ship it"
            )
        )

        // The handoff plist may retain identifiers, but never the unsent text.
        let preferenceValues = fixture.defaults.dictionaryRepresentation().values
        for value in preferenceValues {
            if let data = value as? Data {
                #expect(!String(decoding: data, as: UTF8.self).contains("Ship it"))
                #expect(!String(decoding: data, as: UTF8.self).contains("unsentPrompt"))
            }
            if let string = value as? String {
                #expect(!string.contains("Ship it"))
            }
        }

        let second = fixture.makeTrigger()
        let consumed = second.consume(startupComplete: true)
        #expect(consumed?.serverId == "server-a")
        #expect(consumed?.workspaceId == "ws-1")
        #expect(consumed?.sessionId == "session-1")
        #expect(consumed?.unsentPrompt == "Ship it")
        #expect(second.consume(startupComplete: true) == nil)
    }

    @Test func legacyPendingPromptMovesOutOfPreferencesBeforeConsume() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let oldReceipt: [String: Any] = [
            "requestID": 7,
            "serverId": "server-a",
            "sessionId": "session-1",
            "workspaceId": "ws-1",
            "unsentPrompt": "Legacy unsent text",
        ]
        let key = "\(AppIdentifiers.subsystem).intentSessionOpen.pending"
        fixture.defaults.set(try JSONSerialization.data(withJSONObject: oldReceipt), forKey: key)

        let trigger = fixture.makeTrigger()
        let stored = try #require(fixture.defaults.data(forKey: key))
        #expect(!String(decoding: stored, as: UTF8.self).contains("Legacy unsent text"))
        #expect(!String(decoding: stored, as: UTF8.self).contains("unsentPrompt"))
        let consumed = trigger.consume(startupComplete: true)
        #expect(consumed?.serverId == "server-a")
        #expect(consumed?.sessionId == "session-1")
        #expect(consumed?.unsentPrompt == "Legacy unsent text")
    }

    @Test func failedLegacyPromptMoveLeavesPreferencesIntact() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let key = "\(AppIdentifiers.subsystem).intentSessionOpen.pending"
        let legacyData = try JSONSerialization.data(withJSONObject: [
            "requestID": 8,
            "serverId": "server-a",
            "sessionId": "session-1",
            "workspaceId": "ws-1",
            "unsentPrompt": "Keep on failure",
        ] as [String: Any])
        fixture.defaults.set(legacyData, forKey: key)
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        let blocker = fixture.directory.appending(path: "blocker")
        try Data().write(to: blocker)

        let trigger = IntentSessionOpenTrigger(
            defaults: fixture.defaults,
            promptFileURL: blocker.appending(path: "prompt.json")
        )
        #expect(fixture.defaults.data(forKey: key) == legacyData)
        #expect(trigger.consume(startupComplete: false) == nil)
        // The in-memory receipt still carries the only copy of the prompt.
        #expect(trigger.consume(startupComplete: true)?.unsentPrompt == "Keep on failure")
    }

    @Test func unreadablePromptFileIsRetriedAtConsumeAndNeverDeleted() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let promptURL = fixture.directory.appending(path: "intent-prompt.json")
        fixture.makeTrigger().enqueue(
            fixture.receipt(requestID: 9, sessionId: "session-1", unsentPrompt: "Survive lock")
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: promptURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: promptURL.path) }

        let trigger = fixture.makeTrigger()
        // Still unreadable: the handoff stays pending and the file is kept.
        #expect(trigger.consume(startupComplete: true) == nil)
        #expect(FileManager.default.fileExists(atPath: promptURL.path))

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: promptURL.path)
        let consumed = trigger.consume(startupComplete: true)
        #expect(consumed?.sessionId == "session-1")
        #expect(consumed?.unsentPrompt == "Survive lock")
        #expect(!FileManager.default.fileExists(atPath: promptURL.path))
    }

    @MainActor
    private struct Fixture {
        let suiteName = "IntentSessionOpenTrigger-\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "IntentSessionOpenTrigger-\(UUID().uuidString)", directoryHint: .isDirectory)
        var defaults: UserDefaults { testUnwrap(UserDefaults(suiteName: suiteName)) }

        func makeTrigger() -> IntentSessionOpenTrigger {
            IntentSessionOpenTrigger(
                defaults: defaults,
                promptFileURL: directory.appending(path: "intent-prompt.json")
            )
        }

        func receipt(
            requestID: Int,
            sessionId: String,
            unsentPrompt: String? = nil
        ) -> IntentSessionOpenTrigger.Receipt {
            IntentSessionOpenTrigger.Receipt(
                requestID: requestID,
                serverId: "server-a",
                sessionId: sessionId,
                workspaceId: "ws-1",
                unsentPrompt: unsentPrompt,
                session: nil
            )
        }

        func remove() {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
    }
}

@Suite("StartOppiSessionIntent")
@MainActor
struct StartOppiSessionIntentTests {
    @Test func usesBackgroundThenForegroundDynamic() {
        #expect(StartOppiSessionIntent.supportedModes == [.background, .foreground(.dynamic)])
    }

    @Test func requiresLocalDeviceAuthentication() {
        #expect(StartOppiSessionIntent.authenticationPolicy == .requiresLocalDeviceAuthentication)
    }

    @Test func parameterDefaults() {
        let intent = StartOppiSessionIntent()
        #expect(intent.workspace == nil)
        #expect(intent.server == nil)
    }
}

@Suite("StartOppiSessionConfirmation")
@MainActor
struct StartOppiSessionConfirmationTests {
    private struct DeclinedError: Error {}
    private struct CreateError: Error {}

    private static let limit = StartOppiSessionConfirmation.maxPromptCharacters

    /// Drives the production decide -> confirm -> create order the way `perform()` does.
    private struct Recorded {
        var dialogs: [String] = []
        var sent: [String] = []
        var tooLong = false
        var declined = false
    }

    private func drive(
        rawPrompt: String,
        pairedServerCount: Int = 1,
        decline: Bool = false
    ) async -> Recorded {
        var recorded = Recorded()
        switch StartOppiSessionConfirmation.decide(rawPrompt: rawPrompt) {
        case .tooLong:
            recorded.tooLong = true
        case .confirm(let prompt):
            let result: Int? = try? await StartOppiSessionConfirmation.run(
                prompt: prompt,
                workspaceName: "Oppi",
                serverName: "Studio",
                pairedServerCount: pairedServerCount,
                confirm: { dialog in
                    recorded.dialogs.append(dialog)
                    if decline { throw DeclinedError() }
                },
                create: { text in
                    recorded.sent.append(text)
                    return 1
                }
            )
            recorded.declined = result == nil
        }
        return recorded
    }

    @Test func declineNeverCreates() async {
        let recorded = await drive(rawPrompt: "Fix the build", decline: true)

        #expect(recorded.dialogs.count == 1)
        #expect(recorded.sent.isEmpty)
        #expect(recorded.declined)
    }

    @Test func confirmedPromptIsExactlyWhatTheDialogShowed() async {
        let raw = "  \u{200B}Fix the\u{202E} build\u{2066}\n\nthen run tests\u{200D}  "
        let recorded = await drive(rawPrompt: raw)

        #expect(recorded.sent == ["Fix the build\n\nthen run tests"])
        #expect(recorded.dialogs.count == 1)
        #expect(recorded.dialogs[0].hasSuffix("\n\n" + recorded.sent[0]))
        #expect(!recorded.dialogs[0].contains("…"))
        for scalar in (recorded.dialogs[0] + recorded.sent[0]).unicodeScalars {
            #expect(scalar.properties.generalCategory != .format)
        }
    }

    @Test func newlinePaddingPastTheLimitIsRefusedNotTruncated() async {
        let padded = "Please summarize this."
            + String(repeating: "\n", count: Self.limit)
            + "Then delete everything."
        let recorded = await drive(rawPrompt: padded)

        #expect(recorded.tooLong)
        #expect(recorded.dialogs.isEmpty)
        #expect(recorded.sent.isEmpty)
    }

    @Test func formatCharacterPaddingCannotHideATail() async {
        let padded = "Please summarize this."
            + String(repeating: "\u{200B}", count: Self.limit)
            + " Then delete everything."
        let recorded = await drive(rawPrompt: padded)

        // Padding is stripped, so the whole short prompt is shown and sent.
        #expect(recorded.sent == ["Please summarize this. Then delete everything."])
        #expect(recorded.dialogs[0].contains("Then delete everything."))
    }

    @Test func promptAtTheGraphemeLimitIsConfirmedAndOneOverIsRefused() async {
        let atLimit = String(repeating: "a", count: Self.limit)
        #expect((await drive(rawPrompt: atLimit)).sent == [atLimit])
        #expect((await drive(rawPrompt: atLimit + "a")).tooLong)
    }

    @Test func multiScalarGraphemeCountsOnceAtTheBoundary() async {
        // Skin-tone emoji and a flag are several scalars but one grapheme each.
        for cluster in ["\u{1F44D}\u{1F3FD}", "\u{1F1FA}\u{1F1F8}", "e\u{301}"] {
            let fits = String(repeating: "a", count: Self.limit - 1) + cluster
            #expect(fits.unicodeScalars.count > Self.limit - 1 + 1)
            #expect((await drive(rawPrompt: fits)).sent == [fits])

            let over = String(repeating: "a", count: Self.limit) + cluster
            #expect((await drive(rawPrompt: over)).tooLong)
        }
    }

    @Test func zeroWidthJoinerIsRemovedSoEmojiSequencesSplitIdenticallyInDialogAndSend() async {
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        let recorded = await drive(rawPrompt: family)

        #expect(recorded.sent == ["\u{1F468}\u{1F469}\u{1F467}"])
        #expect(recorded.dialogs[0].hasSuffix(recorded.sent[0]))
    }

    @Test func manyLinesAreRefusedEvenWhenShort() async {
        let max = StartOppiSessionConfirmation.maxPromptLines
        let atLimit = Array(repeating: "x", count: max).joined(separator: "\n")
        let over = Array(repeating: "x", count: max + 1).joined(separator: "\n")

        #expect((await drive(rawPrompt: atLimit)).sent == [atLimit])
        #expect((await drive(rawPrompt: over)).tooLong)
    }

    @Test func promptThatIsOnlyInvisibleCharactersNormalizesToEmpty() {
        #expect(StartOppiSessionConfirmation.normalized("\u{200B}\u{202E}\n \u{2060}").isEmpty)
    }

    @Test func createFailureAfterConfirmationPropagates() async {
        guard case .confirm(let prompt) = StartOppiSessionConfirmation.decide(rawPrompt: "go") else {
            Issue.record("short prompt should be confirmable")
            return
        }
        await #expect(throws: CreateError.self) {
            let _: Int? = try await StartOppiSessionConfirmation.run(
                prompt: prompt,
                workspaceName: "Oppi",
                serverName: "Studio",
                pairedServerCount: 1,
                confirm: { _ in },
                create: { _ in throw CreateError() }
            )
        }
    }

    @Test func dialogOnlyNamesServerWhenSeveralArePaired() async {
        let single = await drive(rawPrompt: "Fix the build", pairedServerCount: 1)
        #expect(single.dialogs[0].contains("Oppi"))
        #expect(!single.dialogs[0].contains("Studio"))

        let multi = await drive(rawPrompt: "Fix the build", pairedServerCount: 2)
        #expect(multi.dialogs[0].contains("Oppi on Studio"))
    }
}
