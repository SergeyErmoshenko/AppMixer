import Foundation
import Testing

@Suite("DeviceUsageStore")
struct DeviceUsageStoreTests {
    private func makeStore() -> DeviceUsageStore {
        let suite = "DeviceUsageStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return DeviceUsageStore(defaults: defaults)
    }

    @Test("round-trips recent entries")
    func roundTrip() {
        let store = makeStore()
        let now = Date()
        let entries = ["uid-speakers": now, "uid-dac": now.addingTimeInterval(-86400)]
        store.save(entries, now: now)
        #expect(store.load() == entries)
    }

    @Test("prunes entries past retention on save")
    func prunes() {
        let store = makeStore()
        let now = Date()
        store.save([
            "uid-fresh": now.addingTimeInterval(-DeviceUsageStore.retention + 60),
            "uid-stale": now.addingTimeInterval(-DeviceUsageStore.retention - 60),
        ], now: now)
        let loaded = store.load()
        #expect(loaded["uid-fresh"] != nil)
        #expect(loaded["uid-stale"] == nil)
    }

    @Test("empty defaults loads empty dictionary")
    func emptyLoad() {
        #expect(makeStore().load().isEmpty)
    }

    @Test("recency boundary")
    func recency() {
        let now = Date()
        #expect(!DeviceUsageStore.isRecent(nil, now: now))
        #expect(DeviceUsageStore.isRecent(now, now: now))
        #expect(DeviceUsageStore.isRecent(now.addingTimeInterval(-DeviceUsageStore.retention + 1), now: now))
        #expect(!DeviceUsageStore.isRecent(now.addingTimeInterval(-DeviceUsageStore.retention), now: now))
    }
}
