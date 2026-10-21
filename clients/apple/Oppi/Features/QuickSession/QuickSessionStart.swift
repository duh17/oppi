import Foundation

/// Everything one Quick Session presentation starts with: where (server,
/// workspace, Agent, thread), how (composer, dictation, or a Live Voice call),
/// and any text or image to put in it. In-app buttons, system controls, and
/// Shortcuts all describe a start this way; `AppOpener` delivers it once App
/// Lock, launch, and the shell are ready.
struct QuickSessionInitialPayload: Equatable, Sendable {
    struct Attachment: Equatable, Sendable {
        let name: String
        let data: Data
        let mimeType: String
    }

    let text: String?
    let attachments: [Attachment]
}

struct QuickSessionStart: Equatable, Sendable {
    var context: QuickSessionLaunchContext?
    var mode: QuickSessionMode = .message
    var payload: QuickSessionInitialPayload?
}
