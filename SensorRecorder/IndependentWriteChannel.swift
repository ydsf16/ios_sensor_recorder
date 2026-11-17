import Foundation

/// Serial ordering per sink, bounded nonblocking admission, and independent I/O execution.
final class IndependentWriteChannel {
    private let label: String
    private let queue: DispatchQueue
    private let lock = NSLock()
    private let maximumBytes: Int
    private let maximumItems: Int
    private var pendingBytes = 0
    private var pendingItems = 0
    private var accepting = true
    private var failure: String?
    private var handler: ((String) -> Void)?

    init(label: String, maximumBytes: Int = 4 * 1024 * 1024, maximumItems: Int = 4096,
         qos: DispatchQoS = .utility) {
        self.label = label
        queue = DispatchQueue(label: label, qos: qos, autoreleaseFrequency: .workItem)
        self.maximumBytes = maximumBytes
        self.maximumItems = maximumItems
    }

    var onFailure: ((String) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return handler }
        set {
            lock.lock(); handler = newValue; let existing = failure; lock.unlock()
            if let existing { newValue?(existing) }
        }
    }

    func reportFailure(_ message: String) {
        lock.lock()
        guard failure == nil else { lock.unlock(); return }
        let description = label + ": " + message
        failure = description
        let callback = handler
        lock.unlock()
        callback?(description)
    }

    @discardableResult
    func enqueue(bytes: Int = 0, _ work: @escaping () throws -> Void) -> Bool {
        let cost = max(0, bytes)
        lock.lock()
        guard accepting, failure == nil else { lock.unlock(); return false }
        guard pendingItems < maximumItems, cost <= maximumBytes - pendingBytes else {
            lock.unlock()
            reportFailure("Write channel backlog exceeded its bounded capacity")
            return false
        }
        pendingItems += 1; pendingBytes += cost
        // Enqueue under the admission lock so finish cannot overtake accepted work.
        queue.async {
            do { try work() } catch { self.reportFailure(error.localizedDescription) }
            self.lock.lock()
            self.pendingItems -= 1; self.pendingBytes -= cost
            self.lock.unlock()
        }
        lock.unlock()
        return true
    }

    /// Stops admission and schedules finalization after all previously admitted writes.
    /// The caller owns asynchronous encoder completion, if needed.
    func finish(_ finalization: @escaping () -> Void) {
        lock.lock()
        accepting = false
        queue.async(execute: finalization)
        lock.unlock()
    }
}
