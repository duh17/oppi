/// Generation token so delayed Photo Library imports cannot attach to a
/// different session or an already-sent draft.
@MainActor
final class ComposerMediaImportGate {
    private(set) var epoch: UInt64 = 0

    func invalidate() {
        epoch &+= 1
    }

    func isCurrent(_ captured: UInt64) -> Bool {
        captured == epoch
    }
}
