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

        let second = fixture.makeTrigger()
        let consumed = second.consume(startupComplete: true)
        #expect(consumed?.sessionId == "session-1")
        #expect(consumed?.unsentPrompt == "Ship it")
        #expect(second.consume(startupComplete: true) == nil)
    }

    @MainActor
    private struct Fixture {
        let suiteName = "IntentSessionOpenTrigger-\(UUID().uuidString)"
        var defaults: UserDefaults { UserDefaults(suiteName: suiteName)! }

        func makeTrigger() -> IntentSessionOpenTrigger {
            IntentSessionOpenTrigger(defaults: defaults)
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
