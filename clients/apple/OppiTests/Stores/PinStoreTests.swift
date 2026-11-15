import Foundation
import os
import Testing
@testable import Oppi

/// `PinStore` saves every change from the revision it holds; when another
/// device changed the pins first, it applies the one change again to the
/// server's list, by id, once.
@Suite("PinStore")
@MainActor
struct PinStoreTests {
    private nonisolated static func pin(_ id: String, _ path: String, label: String? = nil) -> String {
        let label = label.map { #","label":"\#($0)""# } ?? ""
        return #"{"id":"\#(id)","target":{"origin":"host","path":"\#(path)"},"kind":"directory","createdAt":1,"status":"ok"\#(label)}"#
    }

    private nonisolated static func list(_ revision: Int, _ pins: [String]) -> String {
        #"{"revision":\#(revision),"pins":[\#(pins.joined(separator: ","))]}"#
    }

    private nonisolated static func conflict(_ current: String) -> String {
        #"{"error":"Pins changed","code":"revision_conflict","current":\#(current)}"#
    }

    private nonisolated static func respond(_ json: String, status: Int = 200, to request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]
        ))
        return (Data(json.utf8), response)
    }

    private nonisolated static func body(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }

    private struct SentBody: Decodable {
        struct Entry: Decodable { let id: String }
        let baseRevision: Int
        let pins: [Entry]
    }

    private static func sent(_ data: [Data]) throws -> [SentBody] {
        try data.map { try JSONDecoder().decode(SentBody.self, from: $0) }
    }

    private nonisolated static func unplanned(_ request: URLRequest) -> TestURLProtocol.UnplannedRoute {
        TestURLProtocol.UnplannedRoute(route: "\(request.httpMethod ?? "") \(request.url?.path ?? "")")
    }

    @Test func aRemovalThatLosesARaceIsAppliedAgainToTheServersList() async throws {
        let notebook = Self.pin("pin_Notebook0001", "~/notebook")
        let books = Self.pin("pin_Books0000002", "~/Books")
        let reports = Self.pin("pin_Reports00003", "~/reports")
        let first = Self.list(1, [notebook, books])
        // Another device pinned reports before this save.
        let stale = Self.conflict(Self.list(2, [notebook, books, reports]))
        let saved = Self.list(3, [books, reports])
        let puts = OSAllocatedUnfairLock(initialState: [Data]())
        let scope = TestURLProtocol.routeScope { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/pins"):
                return try Self.respond(first, to: request)
            case ("PUT", "/pins"):
                let body = Self.body(request)
                let count = puts.withLock { $0.append(body); return $0.count }
                return count == 1 ? try Self.respond(stale, status: 409, to: request) : try Self.respond(saved, to: request)
            default:
                throw Self.unplanned(request)
            }
        }
        defer { scope.end() }
        let api = makeTestURLProtocolClient()
        let store = PinStore()
        await store.refresh(api: api)

        try await store.remove("pin_Notebook0001", api: api)

        let bodies = try Self.sent(puts.withLock { $0 })
        #expect(bodies.count == 2, "one retry, no more")
        #expect(bodies.first?.baseRevision == 1)
        #expect(bodies.first?.pins.map(\.id) == ["pin_Books0000002"])
        #expect(bodies.last?.baseRevision == 2, "the retry starts from the server's revision")
        #expect(bodies.last?.pins.map(\.id) == ["pin_Books0000002", "pin_Reports00003"], "the other device's pin stays")
        #expect(store.list?.revision == 3)
        #expect(store.pins.map(\.id) == ["pin_Books0000002", "pin_Reports00003"])
    }

    /// A workspace root's Done reorders only that workspace's pins, inside the
    /// places they held; the other pins stay where they were.
    @Test func reorderingSomePinsKeepsTheOthersInPlace() async throws {
        let ids = ["pin_GardenA00001", "pin_Notebook0002", "pin_GardenB00003", "pin_Books0000004", "pin_GardenC00005"]
        let first = Self.list(1, ids.map { Self.pin($0, "~/\($0)") })
        let puts = OSAllocatedUnfairLock(initialState: [Data]())
        let scope = TestURLProtocol.routeScope { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/pins"):
                return try Self.respond(first, to: request)
            case ("PUT", "/pins"):
                let body = Self.body(request)
                puts.withLock { $0.append(body) }
                return try Self.respond(first, to: request)
            default:
                throw Self.unplanned(request)
            }
        }
        defer { scope.end() }
        let api = makeTestURLProtocolClient()
        let store = PinStore()
        await store.refresh(api: api)

        // The section showed A, B, C: C moved first and B was deleted.
        try await store.setOrder(["pin_GardenC00005", "pin_GardenA00001"], removed: ["pin_GardenB00003"], api: api)

        let bodies = try Self.sent(puts.withLock { $0 })
        #expect(bodies.map { $0.pins.map(\.id) } == [["pin_GardenC00005", "pin_Notebook0002", "pin_Books0000004", "pin_GardenA00001"]])
    }

    /// Done with nothing moved or removed writes nothing.
    @Test func doneWithNoChangeSendsNothing() async throws {
        let first = Self.list(1, [Self.pin("pin_Notebook0001", "~/notebook"), Self.pin("pin_Books0000002", "~/Books")])
        let puts = OSAllocatedUnfairLock(initialState: 0)
        let scope = TestURLProtocol.routeScope { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/pins"):
                return try Self.respond(first, to: request)
            case ("PUT", "/pins"):
                puts.withLock { $0 += 1 }
                return try Self.respond(first, to: request)
            default:
                throw Self.unplanned(request)
            }
        }
        defer { scope.end() }
        let api = makeTestURLProtocolClient()
        let store = PinStore()
        await store.refresh(api: api)

        try await store.setOrder(["pin_Books0000002"], removed: [], api: api)

        #expect(puts.withLock { $0 } == 0)
    }

    @Test func aSecondConflictGivesUpAndShowsTheServersList() async throws {
        let first = Self.list(1, [Self.pin("pin_Notebook0001", "~/notebook")])
        let renamed = Self.pin("pin_Notebook0001", "~/notebook", label: "Notes")
        let puts = OSAllocatedUnfairLock(initialState: 0)
        let scope = TestURLProtocol.routeScope { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/pins"):
                return try Self.respond(first, to: request)
            case ("PUT", "/pins"):
                let count = puts.withLock { $0 += 1; return $0 }
                return try Self.respond(Self.conflict(Self.list(1 + count, [renamed])), status: 409, to: request)
            default:
                throw Self.unplanned(request)
            }
        }
        defer { scope.end() }
        let api = makeTestURLProtocolClient()
        let store = PinStore()
        await store.refresh(api: api)

        await #expect(throws: PinsRevisionConflict.self) {
            try await store.rename("pin_Notebook0001", to: "Notebook", api: api)
        }
        #expect(puts.withLock { $0 } == 2)
        #expect(store.list?.revision == 3)
        #expect(store.pins.first?.label == "Notes", "the server's list shows, not the lost rename")
    }
}
