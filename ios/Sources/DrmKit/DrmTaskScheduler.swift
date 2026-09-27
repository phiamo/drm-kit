import Foundation

public protocol DrmScheduledTask: AnyObject {
    func cancel()
}

/// Fixed-rate timers for renewals and heartbeats; injectable so tests drive time by hand.
public protocol DrmTaskScheduler: AnyObject {
    func scheduleAtFixedRate(
        initialDelaySeconds: Int,
        periodSeconds: Int,
        _ work: @escaping () async -> Void
    ) -> DrmScheduledTask
    func shutdown()
}

/// `DispatchSourceTimer` scheduler. Timers keep firing while the app runs in the background
/// (e.g. locked-screen audio), unlike run-loop timers.
public final class DispatchTaskScheduler: DrmTaskScheduler {
    private final class TimerTask: DrmScheduledTask {
        private let timer: DispatchSourceTimer
        private let lock = NSLock()
        private var cancelled = false

        init(timer: DispatchSourceTimer) {
            self.timer = timer
        }

        func cancel() {
            lock.lock()
            defer { lock.unlock() }
            guard !cancelled else { return }
            cancelled = true
            timer.cancel()
        }
    }

    private let queue: DispatchQueue
    private let lock = NSLock()
    private var tasks: [TimerTask] = []

    public init(queue: DispatchQueue = DispatchQueue(label: "org.dwbn.drmkit.fairplay.timers")) {
        self.queue = queue
    }

    public func scheduleAtFixedRate(
        initialDelaySeconds: Int,
        periodSeconds: Int,
        _ work: @escaping () async -> Void
    ) -> DrmScheduledTask {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + .seconds(max(0, initialDelaySeconds)),
            repeating: .seconds(max(1, periodSeconds)),
            leeway: .seconds(1)
        )
        timer.setEventHandler {
            Task { await work() }
        }
        let task = TimerTask(timer: timer)
        lock.lock()
        tasks.append(task)
        lock.unlock()
        timer.resume()
        return task
    }

    public func shutdown() {
        lock.lock()
        let current = tasks
        tasks.removeAll()
        lock.unlock()
        current.forEach { $0.cancel() }
    }
}
