import Foundation

struct DictationDictionaryList: Decodable, Sendable {
    let revision: Int
    let phrases: [String]
    let provider: String?
}

extension APIClient {
    func dictationDictionary(workspaceId: String?) async throws -> DictationDictionaryList {
        let data = try await get(dictionaryPath(workspaceId))
        return try JSONDecoder().decode(DictationDictionaryList.self, from: data)
    }

    func saveDictationDictionary(
        workspaceId: String?, revision: Int, phrases: [String]
    ) async throws -> DictationDictionaryList {
        struct Body: Encodable { let revision: Int; let phrases: [String] }
        let data = try await put(dictionaryPath(workspaceId), body: Body(revision: revision, phrases: phrases))
        return try JSONDecoder().decode(DictationDictionaryList.self, from: data)
    }

    private func dictionaryPath(_ workspaceId: String?) -> String {
        guard let workspaceId else { return "/dictation/dictionary/global" }
        let escaped = workspaceId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
        return "/dictation/dictionary/workspaces/\(escaped)"
    }
}
