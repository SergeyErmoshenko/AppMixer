import Foundation
import Testing

@Suite("DevicePriorityStore")
struct DevicePriorityStoreTests {
    private func makeStore() -> DevicePriorityStore {
        let suite = "DevicePriorityStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return DevicePriorityStore(defaults: defaults)
    }

    @Test("round-trips order")
    func roundTrip() {
        let store = makeStore()
        store.save(["uid-a", "uid-b"])
        #expect(store.load() == ["uid-a", "uid-b"])
        #expect(makeStore().load().isEmpty)
    }

    @Test("merge keeps hidden ranks through a reorder of visible rows")
    func mergePreservesHidden() {
        // AirPods are disconnected, LG is rarely-used — neither is visible.
        // Reordering the visible rows must not strip their ranks, or
        // "AirPods jump to their position on connect" silently breaks.
        let stored = ["builtin", "airpods", "display", "lg"]
        let merged = DevicePriorityStore.merge(stored: stored, visible: ["display", "builtin"])
        #expect(merged == ["display", "airpods", "builtin", "lg"])
    }

    @Test("merge appends new visible devices before slotting")
    func mergeAppendsNew() {
        let merged = DevicePriorityStore.merge(stored: ["a", "b"], visible: ["new", "b", "a"])
        #expect(merged == ["new", "b", "a"])
    }

    @Test("merge with empty stored adopts visible order")
    func mergeEmptyStored() {
        #expect(DevicePriorityStore.merge(stored: [], visible: ["x", "y"]) == ["x", "y"])
    }

    @Test("merge with no visible rows changes nothing")
    func mergeEmptyVisible() {
        #expect(DevicePriorityStore.merge(stored: ["a", "b"], visible: []) == ["a", "b"])
    }
}
