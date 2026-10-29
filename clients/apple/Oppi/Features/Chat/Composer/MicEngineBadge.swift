/// Where dictation runs: the mic button shows a cloud while a server engine
/// listens, and speaks the route in its accessibility value.
enum MicEngineBadge: Equatable, Sendable {
    case onDevice
    case remote
}
