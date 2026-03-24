import CoreGraphics
import Foundation
import Testing
@testable import Oppi

@Suite("DragSelectState")
struct DragSelectStateTests {

    // MARK: - Direction resolution

    @Test func firstUnselectedRowStartsSelectingAction() {
        var state = DragSelectState()
        var selected: Set<String> = []

        state.handleRow("a.swift", selectedPaths: &selected)

        #expect(state.action == .selecting)
        #expect(selected.contains("a.swift"))
    }

    @Test func firstSelectedRowStartsDeselectingAction() {
        var state = DragSelectState()
        var selected: Set<String> = ["a.swift", "b.swift"]

        state.handleRow("a.swift", selectedPaths: &selected)

        #expect(state.action == .deselecting)
        #expect(!selected.contains("a.swift"))
    }

    @Test func directionLocksAfterFirstRow() {
        var state = DragSelectState()
        var selected: Set<String> = ["b.swift"] // b is pre-selected

        // First touch on unselected row → selecting mode
        state.handleRow("a.swift", selectedPaths: &selected)
        #expect(state.action == .selecting)

        // Second touch on already-selected row → still selects (direction locked)
        state.handleRow("b.swift", selectedPaths: &selected)
        #expect(state.action == .selecting)
        #expect(selected.contains("b.swift"), "Should not deselect — direction is locked to selecting")
    }

    // MARK: - Multi-row selection

    @Test func selectsMultipleRowsInSequence() {
        var state = DragSelectState()
        var selected: Set<String> = []

        state.handleRow("a.swift", selectedPaths: &selected)
        state.handleRow("b.swift", selectedPaths: &selected)
        state.handleRow("c.swift", selectedPaths: &selected)

        #expect(selected == ["a.swift", "b.swift", "c.swift"])
    }

    @Test func deselectsMultipleRowsInSequence() {
        var state = DragSelectState()
        var selected: Set<String> = ["a.swift", "b.swift", "c.swift"]

        state.handleRow("a.swift", selectedPaths: &selected)
        state.handleRow("b.swift", selectedPaths: &selected)
        state.handleRow("c.swift", selectedPaths: &selected)

        #expect(selected.isEmpty)
    }

    // MARK: - Visited tracking

    @Test func revisitedRowIsIgnored() {
        var state = DragSelectState()
        var selected: Set<String> = []

        state.handleRow("a.swift", selectedPaths: &selected)
        #expect(selected.contains("a.swift"))

        // Manually remove to test that revisit doesn't re-add
        selected.remove("a.swift")
        let changed = state.handleRow("a.swift", selectedPaths: &selected)

        #expect(!changed, "Revisited row should be no-op")
        #expect(!selected.contains("a.swift"), "Should not re-add a visited row")
    }

    @Test func visitedPathsAccumulate() {
        var state = DragSelectState()
        var selected: Set<String> = []

        state.handleRow("a.swift", selectedPaths: &selected)
        state.handleRow("b.swift", selectedPaths: &selected)

        #expect(state.visitedPaths == ["a.swift", "b.swift"])
    }

    // MARK: - Reset

    @Test func resetClearsAllState() {
        var state = DragSelectState()
        var selected: Set<String> = []

        state.handleRow("a.swift", selectedPaths: &selected)
        state.handleRow("b.swift", selectedPaths: &selected)

        state.reset()

        #expect(state.action == nil)
        #expect(state.visitedPaths.isEmpty)
    }

    @Test func canStartNewDragAfterReset() {
        var state = DragSelectState()
        var selected: Set<String> = []

        // First drag: select a, b
        state.handleRow("a.swift", selectedPaths: &selected)
        state.handleRow("b.swift", selectedPaths: &selected)
        state.reset()

        // Second drag: starts on selected row → deselecting
        state.handleRow("a.swift", selectedPaths: &selected)
        #expect(state.action == .deselecting)
        #expect(!selected.contains("a.swift"))
    }

    // MARK: - Return value

    @Test func returnsTrueOnFirstVisit() {
        var state = DragSelectState()
        var selected: Set<String> = []

        let changed = state.handleRow("a.swift", selectedPaths: &selected)
        #expect(changed == true)
    }

    @Test func returnsFalseOnRevisit() {
        var state = DragSelectState()
        var selected: Set<String> = []

        state.handleRow("a.swift", selectedPaths: &selected)
        let changed = state.handleRow("a.swift", selectedPaths: &selected)
        #expect(changed == false)
    }

    // MARK: - Hit testing

    @Test func pathAtLocationFindsContainingFrame() {
        let frames: [String: CGRect] = [
            "a.swift": CGRect(x: 0, y: 0, width: 300, height: 30),
            "b.swift": CGRect(x: 0, y: 31, width: 300, height: 30),
            "c.swift": CGRect(x: 0, y: 62, width: 300, height: 30),
        ]

        let result = DragSelectState.pathAtLocation(CGPoint(x: 150, y: 45), in: frames)
        #expect(result == "b.swift")
    }

    @Test func pathAtLocationReturnsNilForEmptySpace() {
        let frames: [String: CGRect] = [
            "a.swift": CGRect(x: 0, y: 0, width: 300, height: 30),
        ]

        let result = DragSelectState.pathAtLocation(CGPoint(x: 150, y: 100), in: frames)
        #expect(result == nil)
    }

    @Test func pathAtLocationReturnsNilForEmptyFrames() {
        let result = DragSelectState.pathAtLocation(CGPoint(x: 50, y: 50), in: [:])
        #expect(result == nil)
    }

    // MARK: - Mixed scenario

    @Test func fullDragSelectThenDeselectCycle() {
        var state = DragSelectState()
        var selected: Set<String> = []

        // Drag 1: select a, b, c
        state.handleRow("a.swift", selectedPaths: &selected)
        state.handleRow("b.swift", selectedPaths: &selected)
        state.handleRow("c.swift", selectedPaths: &selected)
        #expect(selected == ["a.swift", "b.swift", "c.swift"])
        state.reset()

        // Drag 2: deselect b, c (starts on selected row)
        state.handleRow("b.swift", selectedPaths: &selected)
        state.handleRow("c.swift", selectedPaths: &selected)
        #expect(selected == ["a.swift"])
        state.reset()

        // Drag 3: re-select b (starts on unselected row)
        state.handleRow("b.swift", selectedPaths: &selected)
        #expect(selected == ["a.swift", "b.swift"])
    }
}
