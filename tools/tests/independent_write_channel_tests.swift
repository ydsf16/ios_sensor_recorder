import Foundation

@main struct IndependentWriteChannelTests {
    static func main() {
        let blocked = IndependentWriteChannel(label: "test.blocked", maximumBytes: 16, maximumItems: 2)
        let free = IndependentWriteChannel(label: "test.free")
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let freeWritten = DispatchSemaphore(value: 0), closed = DispatchSemaphore(value: 0)
        var order: [Int] = [] // Accessed only on blocked's own serial queue.
        var failures = 0
        blocked.onFailure = { _ in failures += 1 }
        assert(blocked.enqueue(bytes: 8) { entered.signal(); release.wait(); order.append(1) })
        assert(entered.wait(timeout: .now() + 2) == .success)
        assert(blocked.enqueue(bytes: 8) { order.append(2) })
        let before = ProcessInfo.processInfo.systemUptime
        assert(!blocked.enqueue(bytes: 1) { fatalError("Overflow must not execute") })
        assert(ProcessInfo.processInfo.systemUptime - before < 0.1, "Admission must not wait for I/O")
        assert(failures == 1)
        free.enqueue { freeWritten.signal() }
        assert(freeWritten.wait(timeout: .now() + 1) == .success, "Other sinks must progress during stalled I/O")
        blocked.finish { assert(order == [1, 2]); closed.signal() }
        assert(closed.wait(timeout: .now() + 0.02) == .timedOut, "Close must wait for accepted writes")
        release.signal()
        assert(closed.wait(timeout: .now() + 2) == .success)
        assert(!blocked.enqueue { fatalError("Closed channel must reject new work") })
        let error = IndependentWriteChannel(label: "test.failed")
        let failed = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
        error.onFailure = { reason in assert(reason.contains("test.failed")); failed.signal() }
        error.enqueue { throw NSError(domain: "disk", code: 28) }
        assert(failed.wait(timeout: .now() + 2) == .success)
        error.finish { finished.signal() }
        assert(finished.wait(timeout: .now() + 2) == .success)
        print("Independent write channels: isolation, FIFO, bounded admission, failure propagation and close barrier PASS")
    }
}
