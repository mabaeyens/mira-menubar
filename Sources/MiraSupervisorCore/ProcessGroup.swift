import Darwin
import Foundation

/// What to run: an explicit executable and argument list, never a shell string.
public struct SpawnSpec: Equatable, Sendable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]
    public var workingDirectory: String
    /// stdout and stderr are appended here when set.
    public var logPath: String?

    public init(executable: String, arguments: [String] = [], environment: [String: String] = [:],
                workingDirectory: String = "/", logPath: String? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.logPath = logPath
    }
}

public enum SpawnError: Error, Equatable, CustomStringConvertible {
    case failed(Int32)
    public var description: String {
        switch self {
        case .failed(let rc): return "could not start the process (\(String(cString: strerror(rc))))"
        }
    }
}

/// Spawns `spec` as the leader of a NEW process group, so that signalling `-pid` reaches the
/// whole tree (the Python server and the inference engine it starts). Without this, killing
/// the leader orphans the children and the next start fails with "port already in use".
public func spawnInOwnGroup(_ spec: SpawnSpec) throws -> pid_t {
    var attr: posix_spawnattr_t? = nil
    posix_spawnattr_init(&attr)
    defer { posix_spawnattr_destroy(&attr) }
    // New group, and a clean signal state: a child inherits ignored or blocked signals from
    // its parent, and a server that ignores SIGTERM would turn every stop into a 10 s wait
    // followed by SIGKILL.
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
    posix_spawnattr_setpgroup(&attr, 0)
    var allSignals = sigset_t()
    sigfillset(&allSignals)
    posix_spawnattr_setsigdefault(&attr, &allSignals)
    var noSignals = sigset_t()
    sigemptyset(&noSignals)
    posix_spawnattr_setsigmask(&attr, &noSignals)

    var actions: posix_spawn_file_actions_t? = nil
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    if #available(macOS 26, *) {
        posix_spawn_file_actions_addchdir(&actions, spec.workingDirectory)
    } else {
        posix_spawn_file_actions_addchdir_np(&actions, spec.workingDirectory)
    }
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
    if let log = spec.logPath {
        posix_spawn_file_actions_addopen(&actions, 1, log, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)
    } else {
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)
    }

    let argv: [UnsafeMutablePointer<CChar>?] = ([spec.executable] + spec.arguments).map { strdup($0) } + [nil]
    let envp: [UnsafeMutablePointer<CChar>?] = spec.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer {
        argv.forEach { free($0) }
        envp.forEach { free($0) }
    }

    var pid: pid_t = 0
    let rc = posix_spawn(&pid, spec.executable, &actions, &attr, argv, envp)
    guard rc == 0 else { throw SpawnError.failed(rc) }
    return pid
}

/// True while any process of the group `pgid` still exists.
func groupExists(_ pgid: pid_t) -> Bool {
    kill(-pgid, 0) == 0
}

/// SIGTERM the whole group, wait up to `grace` seconds for it to empty, then SIGKILL.
/// Returns once the group is gone. Blocking: call from a background queue.
func terminateGroup(_ pgid: pid_t, grace: TimeInterval) {
    guard groupExists(pgid) else { return }
    kill(-pgid, SIGTERM)
    let deadline = Date().addingTimeInterval(grace)
    while groupExists(pgid) && Date() < deadline {
        usleep(100_000)
    }
    if groupExists(pgid) {
        kill(-pgid, SIGKILL)
        var waited = 0
        while groupExists(pgid) && waited < 30 {
            usleep(100_000)
            waited += 1
        }
    }
}

/// Runs a short-lived command to completion, killing its whole group if the task is cancelled.
/// Returns the exit status (128 + signal when it was killed).
public func runToCompletion(_ spec: SpawnSpec) async throws -> Int32 {
    let pid = try spawnInOwnGroup(spec)
    return await withTaskCancellationHandler {
        await withCheckedContinuation { (cont: CheckedContinuation<Int32, Never>) in
            DispatchQueue.global().async {
                var status: Int32 = 0
                while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
                // Reap anything the command left behind.
                terminateGroup(pid, grace: 1)
                if (status & 0x7f) == 0 {
                    cont.resume(returning: (status >> 8) & 0xff)
                } else {
                    cont.resume(returning: 128 + (status & 0x7f))
                }
            }
        }
    } onCancel: {
        kill(-pid, SIGTERM)
    }
}
