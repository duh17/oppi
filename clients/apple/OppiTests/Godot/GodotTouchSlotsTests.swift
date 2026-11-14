import Foundation
import Testing
@testable import Oppi

/// Finger numbers as the engine sees them: stable for a touch's life, and
/// the lowest free number for a new touch, so the first finger down is 0.
@Suite("GodotTouchSlots")
struct GodotTouchSlotsTests {
    private final class Touch {}

    @Test func eachTouchKeepsItsNumberAndANewOneTakesTheLowestFree() {
        var slots = GodotTouchSlots()
        let first = Touch(), second = Touch(), third = Touch()
        #expect(slots.begin(ObjectIdentifier(first)) == 0)
        #expect(slots.begin(ObjectIdentifier(second)) == 1)
        #expect(slots.index(of: ObjectIdentifier(first)) == 0, "A moving touch keeps its number")
        #expect(slots.end(ObjectIdentifier(first)) == 0)
        #expect(slots.index(of: ObjectIdentifier(first)) == nil, "An ended touch has none")
        #expect(slots.begin(ObjectIdentifier(third)) == 0, "The freed 0 goes to the next finger down")
        #expect(slots.index(of: ObjectIdentifier(second)) == 1)
        #expect(slots.removeAll() == [0, 1])
        #expect(slots.index(of: ObjectIdentifier(second)) == nil)
    }

    @Test func aTouchTheEngineNeverSawHasNoNumber() {
        var slots = GodotTouchSlots()
        #expect(slots.index(of: ObjectIdentifier(Touch())) == nil)
        #expect(slots.end(ObjectIdentifier(Touch())) == nil)
    }
}
