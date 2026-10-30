import Foundation

final class Cache: @unchecked Sendable {
    var ready = false
    var value = 0
    let lock = NSLock()

    func warm() {
        lock.withLock { if ready { return } }
        lock.withLock { ready = true }
    }

    func store() { lock.withLock { value = 1 } }
}
