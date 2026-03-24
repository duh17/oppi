import Testing
@testable import Oppi

@Suite("SpinnerStyle")
struct SpinnerStyleTests {

    @Test func displayNameMapping() {
        #expect(SpinnerStyle.brailleDots.displayName == "Pi")
        #expect(SpinnerStyle.gameOfLife.displayName == "GoL")
    }

    @Test func allCasesContainsBothStyles() {
        #expect(SpinnerStyle.allCases.count == 2)
        #expect(SpinnerStyle.allCases.contains(.brailleDots))
        #expect(SpinnerStyle.allCases.contains(.gameOfLife))
    }

    @Test func rawValueRoundTrip() {
        for style in SpinnerStyle.allCases {
            let recovered = SpinnerStyle(rawValue: style.rawValue)
            #expect(recovered == style)
        }
    }
}
