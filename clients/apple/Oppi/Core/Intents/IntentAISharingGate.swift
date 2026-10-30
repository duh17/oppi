import Foundation

/// Siri and Shortcuts cannot show the AI sharing consent sheet, so a send this device has not
/// allowed fails closed: nothing is created or sent, and the dialog says to open Oppi.
enum IntentAISharingGate {
    /// The dialog refusing the send, or nil when this device already allowed the model provider
    /// `modelId` reaches on the server (with no model, the server's default). A catalog that
    /// does not load leaves the provider unnamed, which is refused too.
    @MainActor
    static func refusal(api: APIClient, serverId: String, modelId: String?) async -> String? {
        let catalog = (try? await api.listModels()) ?? []
        let recipient = AISharingConsent.Recipient.modelProvider(modelId: modelId, catalog: catalog)
        if case .refuse(let message) = AISharingConsent.device.decide([recipient], serverId: serverId, canAsk: false) {
            return message
        }
        return nil
    }
}
