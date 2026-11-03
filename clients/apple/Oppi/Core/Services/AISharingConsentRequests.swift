import UIKit

/// The consent ask for a send on one server's connection: which AI services it reaches,
/// read from that connection's model catalog and voice backends, then the sheet.
extension AISharingConsentPrompt {
    /// The AI services a send on `connection`'s server reaches: the model provider of
    /// `modelId` (with none, the server's default) and, for a call, the Live Voice backend.
    static func modelSharingRecipients(
        modelId: String?,
        liveVoice: Bool = false,
        connection: ServerConnection
    ) -> [AISharingConsent.Recipient?] {
        let model = AISharingConsent.Recipient.modelProvider(modelId: modelId, catalog: connection.chatState.cachedModels)
        return liveVoice ? [model, .voice(.liveVoice, backends: connection.voiceBackends)] : [model]
    }

    /// The one ask before content goes to a session's model provider: every in-app send
    /// (prompts, extension answers, branch summaries, a schedule's Run Now, a call) comes
    /// here. A catalog that cannot name the provider yet loads once first. True once every
    /// recipient is allowed; false sends nothing, and the caller keeps what the person entered.
    static func requestModelSharing(
        modelId: String?,
        liveVoice: Bool = false,
        serverId: String?,
        connection: ServerConnection,
        from screen: UIViewController?,
        consent: AISharingConsent = .device
    ) async -> Bool {
        guard let serverId = serverId ?? connection.currentServerId else { return false }
        if modelSharingRecipients(modelId: modelId, liveVoice: liveVoice, connection: connection).contains(nil),
           let api = connection.apiClient {
            await connection.chatState.refreshModelCache(api: api)
        }
        return await request(
            modelSharingRecipients(modelId: modelId, liveVoice: liveVoice, connection: connection),
            serverId: serverId,
            from: screen,
            consent: consent
        )
    }
}
