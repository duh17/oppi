import ActivityKit
import Foundation

/// Oppi's Live Activity: one counts-only card per paired server.
///
/// The app starts and updates it while it runs; the server starts, updates, and ends it through
/// the push relay while the phone is away (protocol/push/spec.md "Live Activity"). Apple and the
/// relay can read every Live Activity payload, so the card carries two counts and nothing else:
/// no session names, tool names, or model text. The relay's push-to-start template names this
/// type (`attributes-type`) and its one attribute, so renaming either breaks remote starts.
///
/// Shared between the main app (request/update/end) and the widget extension (render).
struct OppiActivityAttributes: ActivityAttributes {
    /// The phone's random name for the server this card counts (22 base64url characters). The
    /// relay copies it into the push-to-start payload, so an activity the server started and
    /// one the app started for the same server are the same card.
    let slot: String

    /// Counts are per thread (a top-level session with its subagents). Field names are the
    /// relay template's `content-state` keys, decoded with ActivityKit's default JSON strategy.
    struct ContentState: Codable, Hashable {
        /// Threads running: none of their sessions is blocked, and one is working.
        var running: Int
        /// Threads waiting on the person: a session in them is blocked on an approval, a question,
        /// or a sign-in.
        var needsYou: Int
    }
}
