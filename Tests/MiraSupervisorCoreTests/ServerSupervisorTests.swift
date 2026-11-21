import Darwin
import XCTest
@testable import MiraSupervisorCore

func waitUntil(_ timeout: TimeInterval = 5, _ cond: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if cond() { return true }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return cond()
}

func tmpDir(_ name: String = UUID().uuidString) -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("mira-menubar-tests-\(name)")
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

func processExists(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

final class ServerSupervisorTests: XCTestCase {
    func testStopKillsTheWholeProcessGroup() async throws {
        // The "server" starts a child, like mira-core starting the inference engine.
        let dir = tmpDir()
        let pidfile = dir.appendingPathComponent("child.pid").path
        try? FileManager.default.removeItem(atPath: pidfile)
        let spec = SpawnSpec(executable: "/bin/sh", arguments: ["-c", "sleep 300 & echo $! > '\(pidfile)'; wait"],
                             workingDirectory: dir.path)
        let sup = ServerSupervisor(spec: spec)
        sup.start()

        let appeared = await waitUntil { FileManager.default.fileExists(atPath: pidfile) }
        XCTAssertTrue(appeared)
        let child = pid_t((try String(contentsOfFile: pidfile, encoding: .utf8)).trimmingCharacters(in: .whitespacesAndNewlines))!
        guard case .running(let leader) = sup.state else { return XCTFail("expected running, got \(sup.state)") }
        XCTAssertTrue(processExists(child))

        await sup.stop()

        XCTAssertEqual(sup.state, .stopped)
        let childGone = await waitUntil(3) { !processExists(child) }
        XCTAssertTrue(childGone, "the child must die with the leader, not be orphaned")
        XCTAssertFalse(processExists(leader))
    }

    func testStopEscalatesToSigkillWhenTheServerIgnoresSigterm() async throws {
        var policy = ServerSupervisor.Policy()
        policy.stopGrace = 0.5
        let spec = SpawnSpec(executable: "/bin/sh", arguments: ["-c", "trap '' TERM; while true; do sleep 1; done"])
        let sup = ServerSupervisor(spec: spec, policy: policy)
        sup.start()
        let up = await waitUntil { if case .running = sup.state { return true } else { return false } }
        XCTAssertTrue(up)
        guard case .running(let pid) = sup.state else { return }
        try await Task.sleep(nanoseconds: 300_000_000)  // let the shell install its trap
        await sup.stop()
        XCTAssertEqual(sup.state, .stopped)
        XCTAssertFalse(processExists(pid))
    }

    func testRestartsAfterAnUnexpectedExit() async throws {
        let dir = tmpDir()
        let counter = dir.appendingPathComponent("starts.txt").path
        try? FileManager.default.removeItem(atPath: counter)
        var policy = ServerSupervisor.Policy()
        policy.backoff = [0.05]
        // Dies on its first run, stays up on the second.
        let script = "echo x >> '\(counter)'; if [ $(wc -l < '\(counter)') -lt 2 ]; then exit 1; fi; sleep 300"
        let sup = ServerSupervisor(spec: SpawnSpec(executable: "/bin/sh", arguments: ["-c", script]), policy: policy)
        sup.start()
        let restarted = await waitUntil(5) {
            ((try? String(contentsOfFile: counter, encoding: .utf8)) ?? "").split(separator: "\n").count >= 2
        }
        XCTAssertTrue(restarted)
        let up = await waitUntil { if case .running = sup.state { return true } else { return false } }
        XCTAssertTrue(up)
        await sup.stop()
    }

    func testGivesUpAfterRepeatedCrashes() async throws {
        var policy = ServerSupervisor.Policy()
        policy.backoff = [0.01]
        policy.maxCrashes = 3
        let sup = ServerSupervisor(spec: SpawnSpec(executable: "/bin/sh", arguments: ["-c", "exit 3"]), policy: policy)
        sup.start()
        let failed = await waitUntil(5) { if case .failed = sup.state { return true } else { return false } }
        XCTAssertTrue(failed, "a crash loop must stop and say so, not spin forever; state: \(sup.state)")
    }

    func testAMissingExecutableFailsCleanly() async throws {
        let sup = ServerSupervisor(spec: SpawnSpec(executable: "/nonexistent/python"))
        sup.start()
        let failed = await waitUntil { if case .failed = sup.state { return true } else { return false } }
        XCTAssertTrue(failed)
        // And a later stop must not hang.
        await sup.stop()
    }

    func testOutputGoesToTheLogFile() async throws {
        let dir = tmpDir()
        let log = dir.appendingPathComponent("server.log").path
        try? FileManager.default.removeItem(atPath: log)
        var policy = ServerSupervisor.Policy()
        policy.maxCrashes = 1
        let sup = ServerSupervisor(spec: SpawnSpec(executable: "/bin/sh", arguments: ["-c", "echo hello-from-server; echo oops >&2"],
                                                   logPath: log), policy: policy)
        sup.start()
        _ = await waitUntil { if case .failed = sup.state { return true } else { return false } }
        let text = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
        XCTAssertTrue(text.contains("hello-from-server") && text.contains("oops"))
    }

    func testRunToCompletionReturnsTheExitStatus() async throws {
        let ok = try await runToCompletion(SpawnSpec(executable: "/usr/bin/true"))
        let bad = try await runToCompletion(SpawnSpec(executable: "/bin/sh", arguments: ["-c", "exit 7"]))
        XCTAssertEqual(ok, 0)
        XCTAssertEqual(bad, 7)
    }

    func testCancellingARunKillsItsGroup() async throws {
        let dir = tmpDir()
        let pidfile = dir.appendingPathComponent("c.pid").path
        try? FileManager.default.removeItem(atPath: pidfile)
        let spec = SpawnSpec(executable: "/bin/sh", arguments: ["-c", "sleep 300 & echo $! > '\(pidfile)'; wait"])
        let task = Task { try await runToCompletion(spec) }
        let appeared = await waitUntil { FileManager.default.fileExists(atPath: pidfile) }
        XCTAssertTrue(appeared)
        let child = pid_t((try String(contentsOfFile: pidfile, encoding: .utf8)).trimmingCharacters(in: .whitespacesAndNewlines))!
        task.cancel()
        _ = try? await task.value
        let gone = await waitUntil(3) { !processExists(child) }
        XCTAssertTrue(gone)
    }
}
