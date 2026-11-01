import Testing
import UIKit
import Darwin
@testable import Oppi

/// A Rex session keeps the pane on screen and its neighbours in strip order
/// streaming at once, each into its own terminal, so a swipe shows a pane that
/// is already live instead of reloading it. These run the real connection and
/// the real channel against a fake Rex session (`RexFakeSession`), which serves
/// one data connection per pane.
@Suite("Rex live panes", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct RexLivePanesTests {
    @MainActor
    final class Rig {
        let fake: RexFakeSession
        let channel: SSHTerminalChannel
        let connection: RexSessionConnection
        let model: RexSessionModel
        let consumer: Task<Void, Never>
        /// The terminal's event queue, so a test can feed one pane's stream.
        let queue: SSHTerminalEventQueue

        init(fake: RexFakeSession, channel: SSHTerminalChannel, connection: RexSessionConnection,
             model: RexSessionModel, consumer: Task<Void, Never>, queue: SSHTerminalEventQueue) {
            self.fake = fake
            self.channel = channel
            self.connection = connection
            self.model = model
            self.consumer = consumer
            self.queue = queue
        }

        var rows: [String] {
            channel.engine.frame().rows.map { $0.map(\.text).joined().trimmingCharacters(in: .whitespaces) }
        }

        func shows(_ text: String) -> Bool { rows.contains { $0.contains(text) } }

        /// The pane `block` is streamed on, once its data connection has said HELLO.
        func host(_ block: String) -> RexFakeDataHost? {
            fake.dataHosts.first { $0.block == block }
        }

        /// The stepping the screen uses: the pane a direction names, and
        /// whether its screen is already up.
        func stepping() -> SSHTerminalPaneStepping {
            SSHTerminalPaneStepping(
                neighbour: { [model] delta in model.latest.neighbour(offsetBy: delta)?.name },
                step: { [model] delta in model.step(delta) },
                shown: { [model] in model.latest.shown },
                newPane: { false },
                canCreatePane: { false },
                livePane: { [channel, model] delta in
                    guard let block = model.latest.pane(offsetBy: delta), channel.isReady(block) else { return nil }
                    return block
                },
                target: { [model] delta in model.latest.pane(offsetBy: delta) },
                takeAhead: { [model] block in model.takeAhead(block) }
            )
        }

        func stop() async {
            channel.close(reason: "done")
            consumer.cancel()
            await consumer.value
        }
    }

    static let session = "session:live-panes"
    /// The block `RexFakeSession.new_split` creates first.
    static let created = "block:created-1"
    static func block(_ name: String) -> String { "block:\(name)" }

    private static func makeFake(_ names: [String]) -> RexFakeSession {
        RexFakeSession(sessionID: session, panes: names.map {
            .init(block: block($0), label: "shell", title: "title \($0)", screen: "screen of \($0)\r\n$ ")
        })
    }

    /// A Rex terminal opened on `names[0]`, showing it, then `warm` keeps the
    /// panes beside it live (`RexSessionModel.isWarming`).
    private func open(_ names: [String], warm: Bool = true) async throws -> Rig {
        let fake = Self.makeFake(names)
        let (transport, control) = try await fake.connect()
        let queue = SSHTerminalEventQueue()
        let first = Self.block(names[0])
        let connection = try await RexSessionConnection.open(
            transport: transport, control: control,
            target: RexPaneTarget(sessionID: Self.session, blockID: first, label: "shell"), queue: queue
        )
        let channel = try SSHTerminalChannel(answersTerminalQueries: false)
        let model = RexSessionModel(connection: connection)
        channel.rex = model
        channel.opened(connection)
        let consumer = Task { await channel.consume(queue) }
        // The screen's job, in one line: the session says which pane it shows,
        // and the screen paints it. These tests have no view controller, so this
        // is the wiring a screen would do.
        channel.present(first)
        model.onShown = { [channel] block in channel.present(block) }
        let rig = Rig(
            fake: fake, channel: channel, connection: connection, model: model, consumer: consumer, queue: queue
        )
        channel.resize(.init(columns: 40, rows: 10))
        guard await waitForMainActorCondition(timeout: .seconds(5), { rig.shows("screen of \(names[0])") }) else {
            await rig.stop()
            Issue.record("the opening pane never showed")
            throw CancellationError()
        }
        if warm {
            model.isWarming = true
            let wanted = min(names.count, RexSessionConnection.maximumLivePanes)
            guard await waitForMainActorCondition(timeout: .seconds(5), { fake.dataHosts.count == wanted }) else {
                await rig.stop()
                Issue.record("\(wanted) panes never streamed at once: \(fake.dataHosts.count)")
                throw CancellationError()
            }
        }
        return rig
    }

    /// The shown pane's neighbours stream while the screen shows the session,
    /// one data connection each, without being taken: Rex streams a pane to a
    /// client that does not own it, and a neighbour keeps the size its owner
    /// gave it until the phone shows it. Only the shown pane is taken and
    /// sized for this phone.
    @Test func theNeighboursStreamBesideTheShownPaneWithoutBeingTaken() async throws {
        let rig = try await open(["a", "b", "c"])
        let a = Self.block("a")
        #expect(rig.fake.dataHosts.count == 3)
        #expect(rig.fake.dataHosts.allSatisfy { $0.isWelcomed }, "every lane said HELLO")
        #expect(Set(rig.fake.dataHosts.compactMap(\.block)) == Set(["a", "b", "c"].map(Self.block)))
        #expect(takes(of: a, in: rig) > 0, "the shown pane is taken")
        #expect(await sized(rig, [a]), "and sized for this screen")
        for block in ["b", "c"].map(Self.block) {
            #expect(takes(of: block, in: rig) == 0, "\(block) streams untaken")
            #expect(!rig.fake.requests("com.superlogical.terminal.resize").contains { $0.string("block_id") == block },
                    "\(block) keeps its owner's size")
            #expect(rig.channel.readyEngine(for: block) != nil, "\(block)'s screen is up for a swipe")
        }
        #expect(rig.fake.dataHosts.count == 3, "the cap: three panes, no more")
        await rig.stop()
    }

    /// A switch shows a pane that is already streaming: no new data connection,
    /// one take (the pane it shows, now this phone's size), and its screen is
    /// in its own engine.
    @Test func aSwitchOpensNoStreamAndTakesOnlyThePaneItShows() async throws {
        let rig = try await open(["a", "b", "c"])
        let (b, c) = (Self.block("b"), Self.block("c"))
        #expect(rig.channel.readyEngine(for: b) != nil, "b's screen is already up")
        let connects = rig.fake.requests("data.connect").count
        let owns = rig.fake.requests("session.own_block").count

        rig.model.show(b)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { rig.channel.presented == b || rig.model.latest.shown == b })
        #expect(rig.fake.requests("data.connect").count == connects, "a switch opens no data connection")
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { rig.fake.size(of: b) == Self.phone }, "b is this screen's size")
        let taken = rig.fake.requests("session.own_block").dropFirst(owns)
        #expect(taken.count == 1 && taken.first?.payload.contains(b) == true, "a switch takes the pane it shows, and no other")
        // The grid presents it when the slide ends; the engine it shows is b's.
        rig.channel.present(b)
        #expect(rig.shows("screen of b"))
        #expect(rig.channel.engine === rig.channel.readyEngine(for: b))
        #expect(rig.channel.engine !== rig.channel.readyEngine(for: c))
        await rig.stop()
    }

    /// A pane off screen takes its output into its own engine, and never into
    /// the one on screen.
    @Test func aHiddenPanesOutputStaysInItsOwnTerminal() async throws {
        let rig = try await open(["a", "b", "c"])
        let b = Self.block("b")
        let host = try #require(rig.host(b))
        host.emit("hidden work done\r\n")
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            rig.channel.readyEngine(for: b)?.frame().rows.contains { $0.map(\.text).joined().contains("hidden work done") } == true
        }, "the neighbour's engine took its output")
        #expect(!rig.shows("hidden work done"), "and the screen did not")
        await rig.stop()
    }

    /// Committing past the window slides it: the new far neighbour opens, and
    /// the pane that dropped out is closed and handed back.
    @Test func committingSlidesTheWindowAndHandsBackThePaneLeftBehind() async throws {
        let rig = try await open(["a", "b", "c", "d"])
        let (a, b, c, d) = (Self.block("a"), Self.block("b"), Self.block("c"), Self.block("d"))
        #expect(Set(rig.fake.dataHosts.compactMap(\.block)) == Set([a, b, c]), "a and its next two")

        // a's window is a, b, c. Two panes along is c: b, c, d.
        rig.model.show(c)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { rig.model.latest.shown == c })
        #expect(await waitForMainActorCondition(timeout: .seconds(10)) { rig.host(d) != nil }, "the far neighbour opens")
        // a is two panes behind c: out of the window.
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { rig.host(a)?.isClosed == true })
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            rig.fake.requests("session.disown_block").contains { $0.payload.contains(a) }
        }, "the pane that dropped out goes back to the host's own clients")
        #expect(rig.fake.dataHosts.count == 4, "one lane per pane visited, never more than three open")
        #expect(Set(rig.fake.dataHosts.compactMap(\.block)) == Set([a, b, c, d]))
        #expect(rig.channel.readyEngine(for: d) != nil || rig.host(d)?.isWelcomed == true)
        await rig.stop()
    }

    /// A neighbour's stream that dies is not the terminal's: that pane loses its
    /// lane, and the screen falls back to its card if a swipe reaches it.
    @Test func aNeighboursStreamDyingLeavesTheTerminalAlive() async throws {
        let rig = try await open(["a", "b", "c"])
        let b = Self.block("b")
        let host = try #require(rig.host(b))
        host.end(status: 1)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { rig.host(b)?.isClosed == true })
        // The pane on screen is untouched, and b has no live screen to slide to.
        #expect(rig.channel.connected)
        #expect(rig.shows("screen of a"))
        // Its screen was up before the stream died: the terminal keeps it, so a
        // swipe still has something to show, and the lane is not reopened in a loop.
        #expect(rig.fake.dataHosts.count == 3, "a dead lane is not reopened while the window holds it")
        await rig.stop()
    }

    /// A pane Rex closes while it is off screen only loses its lane: the screen
    /// keeps showing what it has, and the window moves on.
    @Test func aRemotePaneCloseOffScreenDoesNotEndTheTerminal() async throws {
        let rig = try await open(["a", "b", "c"])
        let c = Self.block("c")
        let host = try #require(rig.host(c))
        host.closePane()
        rig.fake.blockClosed(c)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { rig.host(c)?.isClosed == true })
        #expect(rig.channel.connected, "the terminal goes on")
        #expect(rig.shows("screen of a"))
        await rig.stop()
    }

    /// A pane opened with New Pane enters the window like any other.
    @Test func aPaneListChangeMovesTheWindow() async throws {
        let rig = try await open(["a", "b"])
        let created = try await rig.model.newPane()
        #expect(!created.isEmpty)
        #expect(await waitForMainActorCondition(timeout: .seconds(10)) { rig.fake.dataHosts.count == 3 }, "the new pane streams")
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            rig.fake.requests("session.own_block").contains { $0.payload.contains("block:created-1") }
        })
        await rig.stop()
    }

    /// Rotation and keyboard sizes reach the pane on screen, and never a
    /// neighbour this phone has not taken: its owner's size is its own.
    @Test func aResizeReachesThePaneOnScreenAndNoUntakenNeighbour() async throws {
        let rig = try await open(["a", "b", "c"])
        let a = Self.block("a")
        rig.channel.resize(.init(columns: 50, rows: 12))
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            rig.fake.size(of: a) == RexFakeSession.Size(columns: 50, rows: 12)
        }, "the shown pane is 50 columns")
        let resized = Set(rig.fake.requests("com.superlogical.terminal.resize").compactMap { $0.string("block_id") })
        #expect(resized == [a], "resized: \(resized)")
        await rig.stop()
    }

    static let phone = RexFakeSession.Size(columns: 40, rows: 10)

    /// The terminal's takes of `block` so far (`session.own_block`, take).
    private func takes(of block: String, in rig: Rig) -> Int {
        rig.fake.requests("session.own_block").filter {
            $0.payload.contains(block) && $0.payload.contains(#""mode":"take""#)
        }.count
    }

    /// A live pane opened at this screen's size; the test starts from there.
    private func sized(_ rig: Rig, _ blocks: [String]) async -> Bool {
        await waitForMainActorCondition(timeout: .seconds(5)) {
            blocks.allSatisfy { rig.fake.size(of: $0) == Self.phone }
        }
    }

    /// The host's Rex app can take the panes of a session whose layout changes
    /// and size them for its window, so a program started next (pi) draws for
    /// that window, cut at the phone's edge. While the page shows the session,
    /// the phone takes its shown pane back, at this screen's size.
    @Test func theShownPaneAnotherClientTakesComesBackWhileThePageShows() async throws {
        let rig = try await open(["a", "b", "c"])
        let a = Self.block("a")
        #expect(await sized(rig, [a]))
        let before = takes(of: a, in: rig)

        rig.fake.takeAsAnotherClient(a, columns: 120, rows: 40)

        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { rig.fake.size(of: a) == Self.phone },
                "a: \(String(describing: rig.fake.size(of: a)))")
        #expect(takes(of: a, in: rig) > before, "the shown pane is taken back")
        #expect(rig.channel.connected)
        await rig.stop()
    }

    /// A neighbour another client takes keeps that client's size until it is
    /// the pane shown: the swipe may preview it at the other width, and the
    /// switch takes it back.
    @Test func aNeighbourAnotherClientTakesComesBackWhenItIsShown() async throws {
        let rig = try await open(["a", "b", "c"])
        let b = Self.block("b")
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { rig.channel.readyEngine(for: b) != nil })
        let before = takes(of: b, in: rig)

        rig.fake.takeAsAnotherClient(b, columns: 90, rows: 30)
        _ = await waitForMainActorCondition(timeout: .milliseconds(400)) { false }
        #expect(takes(of: b, in: rig) == before, "a neighbour is not taken back while it is off screen")
        #expect(rig.fake.size(of: b) == RexFakeSession.Size(columns: 90, rows: 30))

        rig.model.show(b)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { rig.fake.size(of: b) == Self.phone },
                "b: \(String(describing: rig.fake.size(of: b)))")
        #expect(takes(of: b, in: rig) > before, "the switch takes it back")
        await rig.stop()
    }

    /// Off the page (another tab, the background grace), the phone leaves a
    /// pane another client took alone, and takes it back when the page shows
    /// the session again.
    @Test func aPaneTakenWhileThePageIsAwayComesBackWhenThePageReturns() async throws {
        let rig = try await open(["a", "b", "c"])
        let a = Self.block("a")
        #expect(await sized(rig, [a]))
        rig.model.isWarming = false
        let before = takes(of: a, in: rig)

        rig.fake.takeAsAnotherClient(a, columns: 120, rows: 40)
        _ = await waitForMainActorCondition(timeout: .milliseconds(400)) { false }
        #expect(takes(of: a, in: rig) == before, "no take while the page is away")
        #expect(rig.fake.size(of: a) == RexFakeSession.Size(columns: 120, rows: 40))

        rig.model.isWarming = true
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { rig.fake.size(of: a) == Self.phone },
                "a: \(String(describing: rig.fake.size(of: a)))")
        #expect(takes(of: a, in: rig) > before)
        await rig.stop()
    }

    /// A new pane is the shown pane as soon as the session lists it, so its
    /// stream opens as the shown pane's: taken and sized before `data.connect`,
    /// never first as an untaken neighbour of the pane it was split from.
    @Test func aNewPaneOpensAsTheShownPaneTakenBeforeItStreams() async throws {
        let rig = try await open(["a", "b"])
        let created = try await rig.connection.newPane()
        #expect(rig.connection.state.shown == created, "shown once the view lists it")
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            rig.fake.requests("data.connect").contains { $0.string("block_id") == created }
        })
        let methods = rig.fake.requests.filter { $0.string("block_id") == created || $0.method == "session.own_block" }
        let own = try #require(methods.firstIndex { $0.method == "session.own_block" && $0.payload.contains(created) })
        let resize = try #require(methods.firstIndex { $0.method == "com.superlogical.terminal.resize" && $0.string("block_id") == created })
        let connect = try #require(methods.firstIndex { $0.method == "data.connect" && $0.string("block_id") == created })
        #expect(own < resize && resize < connect)
        await rig.stop()
    }

    /// A finger that has barely moved names no pane: a touch, or a wobble
    /// either way, takes nothing. Only travel past a few points does.
    @Test func aWobbleTakesNoNeighbour() async throws {
        let rig = try await open(["a", "b", "c"])
        let (a, b) = (Self.block("a"), Self.block("b"))
        let screen = try Screen(rig: rig, shown: a)
        let transition = screen.transition

        #expect(transition.beginDrag())
        transition.drag(translationX: 0, neighbour: nil, offersNewPane: false)
        transition.drag(translationX: -3, neighbour: "title b", offersNewPane: false)
        transition.drag(translationX: 2, neighbour: nil, offersNewPane: false)
        _ = await waitForMainActorCondition(timeout: .milliseconds(400)) { false }
        #expect(takes(of: b, in: rig) == 0, "a wobble takes nothing")

        transition.drag(translationX: -40, neighbour: "title b", offersNewPane: false)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { takes(of: b, in: rig) == 1 }, "real travel does")
        transition.endDrag(committing: nil, velocityX: 0)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { transition.phase == .idle })
        screen.dismiss()
        await rig.stop()
    }

    /// A drag toward a live neighbour takes it and sizes it for this screen
    /// while the finger is still down, so the screen sliding in is already laid
    /// out for the phone. A finger going back and forth takes it once.
    @Test func aDragTowardALiveNeighbourTakesItBeforeTheRelease() async throws {
        let rig = try await open(["a", "b", "c"])
        let (a, b) = (Self.block("a"), Self.block("b"))
        let screen = try Screen(rig: rig, shown: a)
        #expect(takes(of: b, in: rig) == 0, "b streams untaken")
        let transition = screen.transition

        #expect(transition.beginDrag())
        transition.drag(translationX: -150, neighbour: "title b", offersNewPane: false)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { rig.fake.size(of: b) == Self.phone },
                "b: \(String(describing: rig.fake.size(of: b)))")
        #expect(transition.phase == .dragging, "before the release")

        transition.drag(translationX: -40, neighbour: "title b", offersNewPane: false)
        transition.drag(translationX: 30, neighbour: nil, offersNewPane: false)
        transition.drag(translationX: -160, neighbour: "title b", offersNewPane: false)
        _ = await waitForMainActorCondition(timeout: .milliseconds(300)) { false }
        #expect(takes(of: b, in: rig) == 1, "one take for the drag")
        #expect(rig.model.latest.shown == a, "the session has not moved")

        transition.endDrag(committing: nil, velocityX: 0)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { transition.phase == .idle })
        screen.dismiss()
        await rig.stop()
    }

    /// The shown pane closes in Rex while the page is away: the session moves
    /// to its neighbour, whose stream opens, but nothing is taken off the page.
    /// The page coming back takes it, once.
    @Test func aPaneShownWhileThePageIsAwayIsTakenWhenThePageReturns() async throws {
        let rig = try await open(["a", "b", "c"])
        let (a, b) = (Self.block("a"), Self.block("b"))
        rig.model.isWarming = false
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { rig.host(b)?.isClosed == true }, "off the page, b's lane closes")
        let before = takes(of: b, in: rig)

        rig.fake.blockClosed(a)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { rig.model.latest.shown == b })
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            rig.fake.dataHosts.contains { $0.block == b && $0.isWelcomed && !$0.isClosed }
        }, "b streams")
        _ = await waitForMainActorCondition(timeout: .milliseconds(400)) { false }
        #expect(takes(of: b, in: rig) == before, "no take while the page is away")

        rig.model.isWarming = true
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { takes(of: b, in: rig) == before + 1 }, "the page returning takes it")
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { rig.fake.size(of: b) == Self.phone })
        _ = await waitForMainActorCondition(timeout: .milliseconds(300)) { false }
        #expect(takes(of: b, in: rig) == before + 1, "once")
        await rig.stop()
    }

    /// A takeover at this screen's own size changes nothing on screen, but
    /// the pane is no longer the phone's: the keyboard's next resize would
    /// wait on Rex for good. The phone takes it back, so the resize lands.
    @Test func aSameSizeTakeoverStillLetsTheNextResizeLand() async throws {
        let rig = try await open(["a", "b", "c"])
        let a = Self.block("a")
        #expect(await sized(rig, [a]))
        let before = takes(of: a, in: rig)

        rig.fake.takeAsAnotherClient(a, columns: Self.phone.columns, rows: Self.phone.rows)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { takes(of: a, in: rig) > before }, "taken back")
        rig.channel.resize(.init(columns: 50, rows: 12))

        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            rig.fake.size(of: a) == RexFakeSession.Size(columns: 50, rows: 12)
        }, "a: \(String(describing: rig.fake.size(of: a)))")
        await rig.stop()
    }

    /// Another client takes the pane the phone just took before Rex answers
    /// that take: both owner changes arrive while the take is still out. The
    /// phone must not count the answer as owning the pane, so it takes it back.
    @Test func aTakeOverThatBeatsTheAnswerToATakeIsTakenBack() async throws {
        let rig = try await open(["a", "b", "c", "d"])
        let d = Self.block("d")
        rig.fake.snatch(d, columns: 120, rows: 40)

        rig.model.show(d)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { rig.fake.size(of: d) == Self.phone },
                "d: \(String(describing: rig.fake.size(of: d)))")
        #expect(takes(of: d, in: rig) == 2, "the switch's take, then one take back")
        await rig.stop()
    }

    /// Two clients that each insist on their own size would trade the pane
    /// forever, redrawing the program on both. The phone takes it back at most
    /// `maximumReclaims` times, then leaves it until its user acts (here,
    /// typing), which earns the same number again.
    @Test func aClientThatAlwaysTakesThePaneBackIsLeftAloneUntilTheUserActs() async throws {
        let rig = try await open(["a", "b", "c"])
        let a = Self.block("a")
        #expect(await sized(rig, [a]))
        let before = takes(of: a, in: rig)
        let cap = RexSessionConnection.maximumReclaims

        rig.fake.fight(for: a, columns: 120, rows: 40)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { takes(of: a, in: rig) - before >= cap })
        _ = await waitForMainActorCondition(timeout: .milliseconds(500)) { false }
        #expect(takes(of: a, in: rig) - before == cap, "the phone stops: \(takes(of: a, in: rig) - before) takes")

        rig.channel.send(Data("x".utf8))
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { takes(of: a, in: rig) - before > cap },
                "typing takes it again")
        _ = await waitForMainActorCondition(timeout: .milliseconds(500)) { false }
        #expect(takes(of: a, in: rig) - before == 2 * cap, "and stops again: \(takes(of: a, in: rig) - before) takes")
        await rig.stop()
    }

    /// A neighbour's copy-on-select must not reach this device's clipboard: it
    /// is not the screen anyone is looking at.
    @Test func aHiddenPanesCopyDoesNotReachTheClipboard() async throws {
        let rig = try await open(["a", "b", "c"])
        rig.channel.isViewed = true
        let (a, b) = (Self.block("a"), Self.block("b"))
        let copy = "\u{1B}]52;c;\(Data("shown".utf8).base64EncodedString())\u{1B}\\"
        try #require(rig.host(a)).emit(copy)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { rig.channel.copies == 1 })
        try #require(rig.host(b)).emit(copy)
        try #require(rig.host(b)).emit(copy)
        // Give the bytes time to land, then check they did not count.
        _ = await waitForMainActorCondition(timeout: .milliseconds(400)) { false }
        #expect(rig.channel.copies == 1, "a hidden pane's copy stays off this device's clipboard")
        await rig.stop()
    }

    /// A session of one pane keeps one lane: nothing to warm, nothing to slide.
    @Test func aSessionOfOnePaneKeepsOneLane() async throws {
        let rig = try await open(["a"])
        _ = await waitForMainActorCondition(timeout: .milliseconds(400)) { false }
        #expect(rig.fake.dataHosts.count == 1)
        #expect(rig.fake.requests("data.connect").count == 1)
        await rig.stop()
    }

    /// The presentation half: a drag to a neighbour that is already streaming
    /// slides in that pane's own screen, not its card, and the commit takes the
    /// pane over without waiting for a snapshot.
    @Test func aDragToALiveNeighbourSlidesInItsOwnScreen() async throws {
        let rig = try await open(["a", "b", "c"])
        let (a, b) = (Self.block("a"), Self.block("b"))
        rig.channel.present(a)
        let window = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let screen = UIWindow(windowScene: window)
        screen.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let host = UIViewController()
        screen.rootViewController = host
        screen.makeKeyAndVisible()
        defer {
            screen.isHidden = true
            screen.rootViewController = nil
        }
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        host.view.addSubview(container)
        let grid = SSHTerminalGridView(channel: rig.channel, paste: { _ in }, followChanged: { _ in })
        grid.frame = container.bounds
        container.addSubview(grid)
        grid.paneStepping = SSHTerminalPaneStepping(
            neighbour: { _ in "b" },
            step: { _ in true },
            shown: { rig.model.latest.shown },
            newPane: { false },
            canCreatePane: { false },
            livePane: { _ in b },
            target: { _ in b },
            takeAhead: { _ in }
        )
        grid.present(a)
        container.layoutIfNeeded()

        let transition = grid.paneTransition
        #expect(transition.beginDrag())
        transition.drag(translationX: -150, neighbour: "b", offersNewPane: false)
        #expect(!transition.isPlaceholderShown, "no card: the pane beside it is live")
        let incoming = try #require(container.subviews.first { $0 is SSHTerminalPanePreview } as? SSHTerminalPanePreview)
        #expect(incoming.block == b)
        #expect(!incoming.isUserInteractionEnabled && incoming.accessibilityElementsHidden, "it never takes input")

        // The release moves the session first, as the grid's swipe does.
        rig.model.show(b)
        transition.endDrag(committing: 1, velocityX: -800)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { transition.phase == .covering })
        #expect(rig.channel.presented == b, "the grid took the pane the slide ended on")
        #expect(container.subviews.contains { $0 === incoming }, "it stays until the grid has drawn that pane")
        transition.frameDrawn()
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { transition.phase == .idle })
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { !container.subviews.contains { $0 === incoming } })
        #expect(rig.shows("screen of b"))
        await rig.stop()
    }


    /// A grid in a window over the rig's channel, armed with the regime's own
    /// stepping, and wired the way the screen wires itself: the session announces
    /// the pane it shows, the grid paints it. That is the one owner under test.
    @MainActor
    final class Screen {
        let window: UIWindow
        let container: UIView
        let grid: SSHTerminalGridView
        var transition: SSHTerminalPaneTransition { grid.paneTransition }

        init(rig: Rig, shown: String) throws {
            let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
            let host = UIViewController()
            window.rootViewController = host
            window.makeKeyAndVisible()
            container = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
            host.view.addSubview(container)
            grid = SSHTerminalGridView(channel: rig.channel, paste: { _ in }, followChanged: { _ in })
            grid.frame = container.bounds
            container.addSubview(grid)
            grid.paneStepping = rig.stepping()
            grid.present(shown)
            container.layoutIfNeeded()
            rig.model.onShown = { [weak grid] _ in
                guard let grid, grid.paneTransition.phase == .idle else { return }
                grid.presentShownPane()
            }
        }

        func dismiss() {
            window.isHidden = true
            window.rootViewController = nil
        }

        /// The incoming side of a swipe, when it is the neighbour's own screen.
        var incoming: SSHTerminalPanePreview? {
            container.subviews.first { $0 is SSHTerminalPanePreview } as? SSHTerminalPanePreview
        }
    }

    /// A pane closed in Rex on screen moves to a neighbour that is already
    /// streaming: nothing brings a snapshot, so the show has to come from the
    /// session's own announcement.
    @Test func aPaneClosedInRexPutsTheLiveNeighbourOnScreen() async throws {
        let rig = try await open(["a", "b", "c"])
        let (a, b) = (Self.block("a"), Self.block("b"))
        let screen = try Screen(rig: rig, shown: a)
        rig.fake.blockClosed(a)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { rig.model.latest.shown == b })
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { rig.channel.presented == b },
                "the screen follows the session, not only a slide")
        #expect(rig.shows("screen of b"))
        // And what that pane prints reaches the grid: a presented pane repaints.
        try #require(rig.host(b)).emit("NEIGHBOUR OUTPUT\r\n")
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { rig.shows("NEIGHBOUR OUTPUT") })
        screen.dismiss()
        await rig.stop()
    }

    /// A new pane whose stream is slow: the card names it, the grid already
    /// shows it underneath, and its snapshot then lifts the card.
    @Test func aNewPaneIsOnTheGridUnderItsCardWhileItsSnapshotArrives() async throws {
        let rig = try await open(["a", "b"])
        let screen = try Screen(rig: rig, shown: Self.block("a"))
        // The new pane's stream is slow: its ticket is held, so its screen cannot
        // arrive while the test looks.
        rig.fake.hold(dataConnectFor: [Self.created])
        let transition = screen.transition
        // The app's order: the card slides in at once (no finger), and Rex's
        // answer lands after the slide has ended.
        transition.slideToNewPane()
        try #require(await waitForMainActorCondition(timeout: .seconds(5)) { transition.phase != .settling },
                     "the slide ends first; Rex's answer comes after it (phase \(transition.phase))")
        #expect(transition.isPlaceholderShown && transition.isAwaitingCreation, "the card waits")
        let name = try await rig.model.newPane()
        let created = try #require(rig.model.latest.panes.first { $0.name == name }?.blockID)
        // Rex answered: the card takes the pane's name, the grid takes the pane
        // underneath it, and the card stays because that pane has no screen yet.
        transition.paneCreated(named: name)
        #expect(rig.channel.presented == created, "the grid took the new pane as the card named it")
        #expect(transition.isPlaceholderShown, "and the card waits over it")
        #expect(!rig.channel.isReady(created), "its stream has not answered")
        transition.frameDrawn()
        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(400)) {
            transition.isPlaceholderShown && transition.isAwaitingCreation == false
        }, "naming it ends the creation wait; only the screen is left")
        screen.dismiss()
        await rig.stop()
    }

    /// A transition torn down mid-slide (a second switch, the screen leaving)
    /// still leaves the pane the session shows on the grid.
    @Test func cancellingASlideShowsThePaneTheSessionShows() async throws {
        let rig = try await open(["a", "b", "c"])
        let (a, b) = (Self.block("a"), Self.block("b"))
        let screen = try Screen(rig: rig, shown: a)
        #expect(screen.transition.beginDrag())
        screen.transition.drag(translationX: -150, neighbour: "b", offersNewPane: false)
        rig.model.show(b)
        screen.transition.endDrag(committing: 1, velocityX: -800)
        screen.transition.cancel()
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { rig.channel.presented == b })
        #expect(rig.shows("screen of b"))
        screen.dismiss()
        await rig.stop()
    }

    /// VoiceOver's Next Pane: the preview and the commit are the pane beside the
    /// one on screen, not the one after it.
    @Test func voiceOverNextPreviewsAndCommitsThePaneBesideIt() async throws {
        let rig = try await open(["a", "b", "c"])
        let (a, b) = (Self.block("a"), Self.block("b"))
        let screen = try Screen(rig: rig, shown: a)
        #expect(screen.grid.stepPane(1))
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { screen.incoming?.block == b },
                "the incoming side is pane 2, not pane 3")
        #expect(!screen.transition.isPlaceholderShown, "and no card: it is live")
        screen.transition.frameDrawn()
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { rig.channel.presented == b })
        screen.dismiss()
        await rig.stop()
    }

    /// A jump from the minimap or the menu to a live pane shows its screen at
    /// once: no card, and no wait for a snapshot that will not come.
    @Test func aJumpToALivePaneShowsItWithoutACard() async throws {
        let rig = try await open(["a", "b", "c"])
        let (a, c) = (Self.block("a"), Self.block("c"))
        let screen = try Screen(rig: rig, shown: a)
        try #require(await waitForMainActorCondition(timeout: .seconds(5)) { rig.channel.isReady(c) },
                     "c's screen is up before the jump")
        screen.transition.slide(toward: 1, neighbour: "title c", target: c)
        #expect(rig.model.show(c))
        #expect(!screen.transition.isPlaceholderShown, "a live pane does not wait behind its card")
        #expect(screen.incoming?.block == c, "its own screen slides in")
        screen.transition.frameDrawn()
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { rig.channel.presented == c })
        #expect(rig.shows("screen of c"))
        screen.dismiss()
        await rig.stop()
    }

    /// A screen the app cannot read for the pane being switched to ends the
    /// terminal, as it always has: that pane is the one the screen stands for,
    /// even before the slide presents it. A pane off screen only loses its lane.
    @Test func anUnreadableScreenForThePaneBeingShownEndsTheTerminal() async throws {
        let rig = try await open(["a", "b", "c"])
        let (a, b) = (Self.block("a"), Self.block("b"))
        rig.channel.present(a)
        // The session moves to b; the grid has not presented it yet.
        rig.model.show(b)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { rig.model.latest.shown == b })
        rig.queue.pushSnapshot(Data([0x00, 0x01, 0x02]), block: b)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { !rig.channel.connected },
                "a pane with no readable screen ends the terminal: \(rig.channel.reason)")
        #expect(rig.channel.reason == SSHTerminalSnapshotFormat.unreadable)
        await rig.stop()
    }

    /// A jump to a pane Rex refuses goes back to the pane the screen was on, not
    /// to a neighbour that happened to draw last.
    @Test func aRefusedJumpRecoversToThePaneOnScreen() async throws {
        let rig = try await open(["a", "b", "c", "d"])
        let (a, d) = (Self.block("a"), Self.block("d"))
        rig.fake.hold(dataConnectFor: [d])
        rig.model.show(d)
        try #require(await waitForMainActorCondition(timeout: .seconds(5)) {
            rig.fake.requests("data.connect").contains { $0.string("block_id") == d }
        })
        rig.fake.refuse(dataConnectFor: d)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { rig.model.latest.shown == a },
                "back to a, the pane on screen: \(rig.model.latest.shown)")
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { rig.channel.isReady(a) },
                "and its stream came back")
        await rig.stop()
    }

    /// The New Pane card waits for the pane Rex is making, not for the pane the
    /// session still shows: that pane drawing (a busy agent prints all the time)
    /// must not lift the card and drop the person back on it.
    @Test func theNewPaneCardWaitsWhileTheOldPaneDraws() async throws {
        let rig = try await open(["a", "b"])
        let screen = try Screen(rig: rig, shown: Self.block("a"))
        let transition = screen.transition
        transition.slideToNewPane()
        // The slide settles; the card is what waits. (With the bug the card is
        // gone by now: a frame of the pane still on screen lifted it.)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { transition.phase != .settling },
                "the slide settles (phase \(transition.phase))")
        #expect(transition.isAwaitingCreation)
        // The pane the session still shows is live and keeps drawing.
        try #require(await waitForMainActorCondition(timeout: .seconds(5)) { rig.channel.isReady(Self.block("a")) })
        transition.frameDrawn()
        try #require(rig.host(Self.block("a"))).emit("still working\r\n")
        transition.frameDrawn()
        try #require(transition.isPlaceholderShown && transition.isAwaitingCreation,
                     "the card waits for the new pane, not for the pane still on screen")
        #expect(transition.placeholderTitle?.isEmpty == false)
        screen.dismiss()
        await rig.stop()
    }

    /// A second switch onto a pane that is already live does not wait behind the
    /// card the first switch put up: its screen is there, so the card lifts on the
    /// next frame rather than waiting out `revealTimeout` for a snapshot that will
    /// never come.
    @Test func aSecondSwitchOntoALivePaneLiftsTheCardAtOnce() async throws {
        let rig = try await open(["a", "b", "c", "d"])
        let (a, c, d) = (Self.block("a"), Self.block("c"), Self.block("d"))
        let screen = try Screen(rig: rig, shown: a)
        let transition = screen.transition
        transition.revealTimeout = .seconds(5)
        // The first switch heads for d, which has no screen yet: a card.
        rig.fake.hold(dataConnectFor: [d])
        transition.slide(toward: 1, neighbour: "title d", target: d)
        #expect(rig.model.show(d))
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { transition.phase == .settling })
        // The second heads for c, which is live.
        try #require(await waitForMainActorCondition(timeout: .seconds(5)) { rig.channel.isReady(c) })
        transition.slide(toward: -1, neighbour: "title c", target: c)
        #expect(rig.model.show(c))
        // A test host's grid does not draw on its own, so the app's next frame is
        // this call. `revealTimeout` is 5 s: settling quickly is the point, and
        // `covering` can lift in the same turn, so the outcome is what is asserted.
        transition.frameDrawn()
        #expect(await waitForMainActorCondition(timeout: .seconds(2)) { transition.phase == .idle },
                "the card lifts on the frame, not after the wait")
        screen.dismiss()
        await rig.stop()
    }

    /// The window never exceeds the cap, even on a long strip.
    @Test func theWindowIsThreePanesAtMost() async throws {
        let rig = try await open(["a", "b", "c", "d", "e", "f"])
        _ = await waitForMainActorCondition(timeout: .milliseconds(400)) { false }
        #expect(rig.fake.dataHosts.count == RexSessionConnection.maximumLivePanes)
        #expect(Set(rig.fake.dataHosts.compactMap(\.block)) == Set(["a", "b", "c"].map(Self.block)), "a and its next two")
        await rig.stop()
    }
}
