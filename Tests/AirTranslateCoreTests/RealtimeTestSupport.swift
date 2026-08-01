import Foundation
@testable import AirTranslate

final class RealtimeAudioDegradationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedEvents: [RealtimeAudioTransportDegradation] = []

    var events: [RealtimeAudioTransportDegradation] {
        lock.lock()
        defer { lock.unlock() }
        return storedEvents
    }

    func record(_ event: RealtimeAudioTransportDegradation) {
        lock.lock()
        storedEvents.append(event)
        lock.unlock()
    }
}

final class StandardUserDefaultsTestLock: @unchecked Sendable {
    static let shared = StandardUserDefaultsTestLock()

    private let lock = NSRecursiveLock()

    private init() {}

    func withLock<Result>(_ body: () throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
