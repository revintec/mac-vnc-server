import Darwin
import Foundation

/// Signal callbacks must not inherit MainActor isolation from the AppKit entry
/// point. A separate queue and deadline also keep cancellation handlers that
/// block in framework cleanup from swallowing later interrupts.
final class ProcessShutdown: @unchecked Sendable {
    static let shared = ProcessShutdown()
    private let lock = NSLock()
    private let signalQueue = DispatchQueue(label: "mac-vnc-server.signals", qos: .userInitiated)
    private let deadlineQueue = DispatchQueue(label: "mac-vnc-server.exit-deadline", qos: .userInitiated)
    private let gracePeriod: TimeInterval
    private let exitProcess: @Sendable (Int32) -> Void
    private var sources: [DispatchSourceSignal] = []
    private var runner: Task<Void, Never>?
    private var signals: [Int32: UInt] = [:]
    private var firstSignal: Int32?
    private var deadline: DispatchWorkItem?
    private var forced = false
    private var children: [UUID: Process] = [:]

    init(gracePeriod: TimeInterval = 5,
         exitProcess: @escaping @Sendable (Int32) -> Void = { Darwin._exit($0) }) {
        self.gracePeriod = gracePeriod
        self.exitProcess = exitProcess
    }

    func installSignalHandlers() {
        for number in [SIGINT, SIGTERM] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: signalQueue)
            source.setEventHandler { @Sendable [weak self, weak source] in
                self?.request(number, count: max(1, source?.data ?? 1))
            }
            sources.append(source)
            source.resume()
        }
    }

    func attach(_ task: Task<Void, Never>) {
        let cancel = lock.withLock { runner = task; return firstSignal != nil }
        if cancel { task.cancel() }
    }

    func request(_ number: Int32, count: UInt = 1) {
        let action: (Task<Void, Never>?, Bool, Bool) = lock.withLock {
            guard !forced else { return (nil, false, false) }
            signals[number, default: 0] += count
            if signals[number, default: 0] > 1 { return (nil, false, true) }
            guard firstSignal == nil else { return (nil, false, false) }
            firstSignal = number
            return (runner, true, runner == nil)
        }
        if action.2 { forceExit(number); return }
        guard action.1 else { return }
        let timer = DispatchWorkItem { [weak self] in self?.forceExit(number) }
        lock.withLock { deadline = timer }
        deadlineQueue.asyncAfter(deadline: .now() + gracePeriod, execute: timer)
        // Task.cancel invokes cancellation handlers synchronously. It must not
        // occupy either the signal queue or the forced-exit deadline queue.
        DispatchQueue.global(qos: .userInitiated).async { action.0?.cancel() }
    }

    func register(_ process: Process) -> UUID {
        let token = UUID()
        let stopping = lock.withLock { children[token] = process; return firstSignal != nil }
        if stopping, process.isRunning { kill(process.processIdentifier, SIGTERM) }
        return token
    }

    func unregister(_ token: UUID) { _ = lock.withLock { children.removeValue(forKey: token) } }

    private func forceExit(_ number: Int32) {
        let processes: [Process]? = lock.withLock {
            guard !forced else { return nil }
            forced = true
            return Array(children.values)
        }
        guard let processes else { return }
        // Only kill workers this supervisor launched, never a process group or
        // another endpoint. Foundation marks reaped children as not running.
        for process in processes where process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        exitProcess(128 + number)
    }
}
