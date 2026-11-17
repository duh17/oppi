import Foundation

extension APIClient {
    /// `GET /pins`: every pin with what the server finds at its target now.
    func listPins() async throws -> PinsList {
        try JSONDecoder().decode(PinsList.self, from: try await get("/pins"))
    }

    /// `POST /pins`: pins `target`; a route already pinned answers its pin.
    func addPin(_ target: PaneRoute, label: String? = nil) async throws -> PinAddResult {
        struct Body: Encodable { let target: PaneRoute; let label: String? }
        let data = try await post("/pins", body: Body(target: target, label: label))
        return try JSONDecoder().decode(PinAddResult.self, from: data)
    }

    /// `PUT /pins`: the pins in this order with these labels; the rest are
    /// removed. A stale `baseRevision` throws `PinsRevisionConflict`.
    func savePins(baseRevision: Int, _ pins: [PinOrderEntry]) async throws -> PinsList {
        struct Body: Encodable { let baseRevision: Int; let pins: [PinOrderEntry] }
        let (data, response) = try await request("PUT", path: "/pins", body: Body(baseRevision: baseRevision, pins: pins))
        if (response as? HTTPURLResponse)?.statusCode == 409 {
            struct Conflict: Decodable { let current: PinsList }
            if let conflict = try? JSONDecoder().decode(Conflict.self, from: data) {
                throw PinsRevisionConflict(current: conflict.current)
            }
        }
        try checkStatus(response, data: data)
        return try JSONDecoder().decode(PinsList.self, from: data)
    }
}
