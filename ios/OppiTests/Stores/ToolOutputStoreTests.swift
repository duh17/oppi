import Testing
@testable import Oppi

@MainActor
@Suite("ToolOutputStore")
struct ToolOutputStoreTests {

    @Test func basicAppendAndRetrieve() {
        let store = ToolOutputStore()
        store.append("hello ", to: "t1")
        store.append("world", to: "t1")
        #expect(store.fullOutput(for: "t1") == "hello world")
        #expect(store.byteCount(for: "t1") == 11)
        #expect(store.totalBytes == 11)
    }

    @Test func perItemCapEnforced() {
        let store = ToolOutputStore()
        let bigChunk = String(repeating: "x", count: ToolOutputStore.perItemCap + 1000)
        store.append(bigChunk, to: "t1")

        let output = store.fullOutput(for: "t1")
        // Should be capped at perItemCap + truncation marker
        #expect(output.hasSuffix(ToolOutputStore.truncationMarker))
        #expect(output.utf8.count <= ToolOutputStore.perItemCap + ToolOutputStore.truncationMarker.utf8.count + 4)  // +4 for possible char boundary
    }

    @Test func perItemCapStopsSubsequentAppends() {
        let store = ToolOutputStore()
        // Fill to exactly the cap
        let fillChunk = String(repeating: "a", count: ToolOutputStore.perItemCap)
        store.append(fillChunk, to: "t1")
        let sizeAfterFill = store.byteCount(for: "t1")

        // Further appends should be no-ops
        store.append("more data", to: "t1")
        #expect(store.byteCount(for: "t1") == sizeAfterFill)
    }

    @Test func mediaSizedDataUriFitsWithoutTruncation() {
        let store = ToolOutputStore()
        let base64 = String(repeating: "A", count: 700_000)
        let output = "Read image file [image/png]\ndata:image/png;base64,\(base64)"

        store.append(output, to: "img")

        #expect(!store.fullOutput(for: "img").hasSuffix(ToolOutputStore.truncationMarker))
        #expect(store.fullOutput(for: "img") == output)
    }

    @Test func totalCapEvictsOldest() {
        let store = ToolOutputStore()
        // Each chunk is per-item cap; inserting enough items should force FIFO eviction
        let chunkSize = ToolOutputStore.perItemCap
        let chunk = String(repeating: "x", count: chunkSize)

        // Insert many items — should evict oldest to stay under totalCap
        for i in 0..<12 {
            store.append(chunk, to: "t\(i)")
        }

        // Oldest items should be evicted
        #expect(store.totalBytes <= ToolOutputStore.totalCap)
        // First items should be gone
        #expect(store.fullOutput(for: "t0").isEmpty)
        #expect(store.fullOutput(for: "t1").isEmpty)
        // Recent items should still be present
        #expect(!store.fullOutput(for: "t11").isEmpty)
    }

    @Test func clearRemovesSpecificItems() {
        let store = ToolOutputStore()
        store.append("aaa", to: "t1")
        store.append("bbb", to: "t2")
        store.append("ccc", to: "t3")
        #expect(store.totalBytes == 9)

        store.clear(itemIDs: ["t1", "t3"])
        #expect(store.fullOutput(for: "t1").isEmpty)
        #expect(store.fullOutput(for: "t2") == "bbb")
        #expect(store.fullOutput(for: "t3").isEmpty)
        #expect(store.totalBytes == 3)
    }

    @Test func clearAllResetsEverything() {
        let store = ToolOutputStore()
        store.append("data", to: "t1")
        store.append("data", to: "t2")
        store.clearAll()
        #expect(store.totalBytes == 0)
        #expect(store.fullOutput(for: "t1").isEmpty)
    }
}
