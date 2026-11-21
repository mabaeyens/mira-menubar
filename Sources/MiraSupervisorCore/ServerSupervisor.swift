import Darwin
import Foundation

public enum SupervisorState: Equatable, Sendable {
    case stopped
    case starting
    case running(pid: Int32)
    case stopping
    /// Gave up after repeated crashes, or could not start at all. Needs a manual Start.
    case failed(String)
}

/// Owns the server process: starts it as a process group, restarts it with backoff when it
/// dies unexpectedly, and stops the whole group on request. All state lives on one serial queue.
public final class ServerSupervisor: @unchecked Sendable {
    public struct Policy: Sendable {
        /// Delay before restart n (1-based); the last value repeats.
        public var backoff: [TimeInterval] = [1, 2, 5, 10, 30]
        /// Give up when the server dies this many times within `window`.
        public var maxCrashes = 5
        public var window: TimeInterval = 120
        /// SIGTERM to SIGKILL grace when stopping.
        public var stopGrace: TimeInterval = 10
        public init() {}
    }

    private let queue = DispatchQueue(label: "mira.supervisor")
    private let spec: SpawnSpec
    private let policy: Policy
    private var pid: pid_t = 0
    private var source: DispatchSourceProcess?
    private var wantRunning = false
    private var crashes: [Date] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var _state: SupervisorState = .stopped
    private var observers: [(SupervisorState) -> Void] = []

    public init(spec: SpawnSpec, policy: Policy = Policy()) {
        self.spec = spec
        self.policy = policy
    }

    public var state: SupervisorState { queue.sync { _state } }

    /// Called on an arbitrary queue on every state change.
    public func observe(_ handler: @escaping (SupervisorState) -> Void) {
        queue.sync { observers.append(handler) }
    }

    public func start() {
        queue.async {
            self.wantRunning = true
            self.crashes.removeAll()
            self.launch()
        }
    }

    /// Stops the server and everything it started. Returns when the group is gone.
    public func stop() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                self.wantRunning = false
                guard self.pid != 0 else {
                    if case .stopped = self._state {} else { self.set(.stopped) }
                    cont.resume()
                    return
                }
                self.waiters.append(cont)
                self.set(.stopping)
                let target = self.pid
                let grace = self.policy.stopGrace
                // Signal off the supervisor queue: terminateGroup blocks while it waits.
                DispatchQueue.global().async { terminateGroup(target, grace: grace) }
            }
        }
    }

    public func restart() async {
        await stop()
        start()
    }

    // MARK: - queue-confined

    private func set(_ new: SupervisorState) {
        guard new != _state else { return }
        _state = new
        let hs = observers
        hs.forEach { $0(new) }
    }

    private func launch() {
        guard pid == 0 else { return }
        set(.starting)
        do {
            let p = try spawnInOwnGroup(spec)
            pid = p
            set(.running(pid: p))
            watch(p)
        } catch {
            wantRunning = false
            set(.failed("\(error)"))
        }
    }

    private func watch(_ p: pid_t) {
        let src = DispatchSource.makeProcessSource(identifier: p, eventMask: .exit, queue: queue)
        src.setEventHandler { [weak self] in self?.exited(p) }
        source = src
        src.resume()
    }

    private func exited(_ p: pid_t) {
        guard p == pid else { return }
        var status: Int32 = 0
        while waitpid(p, &status, WNOHANG) < 0 && errno == EINTR {}
        source?.cancel()
        source = nil
        pid = 0
        // The leader is gone; anything it left in the group (the engine) goes too.
        DispatchQueue.global().async { terminateGroup(p, grace: 3) }

        let resumed = waiters
        waiters.removeAll()

        if !wantRunning {
            set(.stopped)
            resumed.forEach { $0.resume() }
            return
        }
        let now = Date()
        crashes = crashes.filter { now.timeIntervalSince($0) < policy.window } + [now]
        if crashes.count >= policy.maxCrashes {
            wantRunning = false
            set(.failed("the server stopped \(crashes.count) times in \(Int(policy.window)) s; see the log"))
            resumed.forEach { $0.resume() }
            return
        }
        set(.starting)
        let delay = policy.backoff[min(crashes.count - 1, policy.backoff.count - 1)]
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.wantRunning, self.pid == 0 else { return }
            self.launch()
        }
        resumed.forEach { $0.resume() }
    }
}
