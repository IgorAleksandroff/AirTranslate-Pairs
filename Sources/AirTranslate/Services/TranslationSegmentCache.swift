import Foundation

struct TranslationSegmentCache {
    private struct Entry {
        var value: String
        var lastAccess: Int
    }

    private let capacity: Int
    private var entries: [String: Entry] = [:]
    private var accessCounter = 0

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    var count: Int {
        entries.count
    }

    mutating func value(forKey key: String) -> String? {
        guard var entry = entries[key] else { return nil }

        entry.lastAccess = nextAccess()
        entries[key] = entry
        return entry.value
    }

    mutating func insert(_ value: String, forKey key: String) {
        entries[key] = Entry(value: value, lastAccess: nextAccess())
        guard entries.count > capacity else { return }

        guard let leastRecentlyUsedKey = entries.min(by: {
            $0.value.lastAccess < $1.value.lastAccess
        })?.key else {
            return
        }
        entries.removeValue(forKey: leastRecentlyUsedKey)
    }

    mutating func removeAll() {
        entries.removeAll(keepingCapacity: true)
        accessCounter = 0
    }

    private mutating func nextAccess() -> Int {
        accessCounter += 1
        return accessCounter
    }
}
