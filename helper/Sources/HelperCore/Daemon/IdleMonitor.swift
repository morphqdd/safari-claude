import Foundation

/// One-shot timer on a serial queue. `arm()` (re)schedules, `disarm()` cancels. No repeating timers.
final class IdleMonitor {
    private let queue: DispatchQueue
    private let delay: TimeInterval
    private let action: () -> Void
    private var work: DispatchWorkItem?

    init(queue: DispatchQueue, delay: TimeInterval, action: @escaping () -> Void) {
        self.queue = queue
        self.delay = delay
        self.action = action
    }

    func arm() {
        work?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.work = nil
            self?.action()
        }
        work = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    func disarm() {
        work?.cancel()
        work = nil
    }
}
