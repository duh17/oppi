import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Oppi

@Suite("SessionStatusPill palette")
struct SessionStatusPillTests {
    /// Working blue; every blocked kind the same orange; Done green and Error red (both only
    /// while unseen); Idle and Stopped neutral greys that never read as green.
    @Test func statusPaletteSeparatesWorkingBlockedAndUnseenOutcomes() {
        let theme = ThemeID.dark.appTheme
        func color(_ kind: SessionStatusKind) -> UIColor { UIColor(kind.tint(theme)) }

        #expect(color(.working) == UIColor(theme.accent.blue))
        for blocked in [SessionStatusKind.needsApproval, .question, .signIn] {
            #expect(color(blocked) == UIColor(theme.accent.orange))
        }
        #expect(color(.done) == UIColor(theme.accent.green))
        #expect(color(.error) == UIColor(theme.accent.red))
        #expect(color(.idle) == UIColor(theme.text.secondary))
        #expect(color(.stopped) == UIColor(theme.text.tertiary))
        #expect(color(.idle) != color(.done))
    }

    @Test func rowCarriesSeenStateIntoItsStatus() {
        let since = Date(timeIntervalSince1970: 1_000)
        let session = makeTestSession(
            status: .ready,
            programStatus: ProgramStatus(state: .done, since: since),
            messageCount: 2,
            firstMessage: "go"
        )

        let unseen = SessionRowPresentationBuilder.make(session: session, seenAt: since.addingTimeInterval(-1))
        let seen = SessionRowPresentationBuilder.make(session: session, seenAt: since)

        #expect(unseen.statusKind == .done)
        #expect(seen.statusKind == .idle)
    }
}
