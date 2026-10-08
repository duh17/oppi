import Foundation
import Testing
@testable import Oppi

@Suite("Dictation dictionary API client", .serialized)
struct DictationDictionaryAPIClientTests {
    @Test func dictionaryResponseDecodesAlongsideBulkAddMetadata() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TestURLProtocol.self]
        let client = try APIClient(
            baseURL: #require(URL(string: "http://localhost:7749")),
            token: "sk_test", configuration: config
        )
        defer { TestURLProtocol.handler = nil }
        TestURLProtocol.handler = { request in
            #expect(request.httpMethod == "GET")
            #expect(request.url?.path == "/dictation/dictionary/global")
            let data = Data(#"{"phrases":["Yuwp"],"revision":4,"added":1,"skipped":[{"phrase":"duplicate","reason":"duplicate"}]}"#.utf8)
            let url = testUnwrap(request.url)
            let response = try #require(HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            ))
            return (data, response)
        }
        let result = try await client.dictationDictionary(workspaceId: nil)
        #expect(result.phrases == ["Yuwp"])
        #expect(result.revision == 4)
    }
}
