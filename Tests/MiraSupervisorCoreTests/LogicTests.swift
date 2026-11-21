import XCTest
@testable import MiraSupervisorCore

final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (code, body) = Self.handler?(request) ?? (500, Data())
        let resp = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class HealthClientTests: XCTestCase {
    private func client(token: String? = nil) -> HealthClient {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self]
        return HealthClient(session: URLSession(configuration: cfg), token: token)
    }

    func testParsesAnEngineAwareHealthReply() async {
        StubURLProtocol.handler = { _ in (200, Data(#"{"status":"ok","backend_ready":true,"engine_state":"sleeping"}"#.utf8)) }
        let s = await client().snapshot()
        XCTAssertEqual(s, HealthSnapshot(reachable: true, backendReady: true, engineState: .sleeping))
    }

    func testAnOlderServerHasNoEngineState() async {
        StubURLProtocol.handler = { _ in (200, Data(#"{"status":"ok","backend_ready":true}"#.utf8)) }
        let s = await client().snapshot()
        XCTAssertEqual(s.engineState, nil)
        XCTAssertTrue(s.reachable && s.backendReady)
    }

    func testServerErrorsAndGarbageAreUnreachable() async {
        StubURLProtocol.handler = { _ in (503, Data()) }
        let a = await client().snapshot()
        StubURLProtocol.handler = { _ in (200, Data("not json".utf8)) }
        let b = await client().snapshot()
        XCTAssertEqual(a, .unreachable)
        XCTAssertEqual(b, .unreachable)
    }

    func testUnloadReportsRefusalAndSendsTheToken() async {
        nonisolated(unsafe) var seen: URLRequest?
        StubURLProtocol.handler = { req in seen = req; return (409, Data()) }
        let refused = await client(token: "t0k").unload()
        XCTAssertFalse(refused)
        XCTAssertEqual(seen?.httpMethod, "POST")
        XCTAssertEqual(seen?.url?.path, "/engine/unload")
        XCTAssertEqual(seen?.value(forHTTPHeaderField: "Authorization"), "Bearer t0k")
        StubURLProtocol.handler = { _ in (200, Data()) }
        let accepted = await client().wake()
        XCTAssertTrue(accepted)
    }
}

final class PreflightTests: XCTestCase {
    private let gib: UInt64 = 1 << 30

    func testA32GBMacWithRoomGetsTheLargeModel() {
        let r = Preflight.evaluate(ramBytes: 32 * gib, freeBytes: 200_000_000_000)
        XCTAssertEqual(r.tier, .large)
        XCTAssertTrue(r.ok)
        XCTAssertTrue(r.warnings.isEmpty)
    }

    func testBelow31GiBGetsTheSmallModelWithAWarning() {
        let r = Preflight.evaluate(ramBytes: 24 * gib, freeBytes: 100_000_000_000)
        XCTAssertEqual(r.tier, .small)
        XCTAssertTrue(r.ok)
        XCTAssertEqual(r.warnings.count, 1)
    }

    func testUnder16GBIsRefused() {
        let r = Preflight.evaluate(ramBytes: 8 * gib, freeBytes: 100_000_000_000)
        XCTAssertFalse(r.ok)
        XCTAssertTrue(r.problems[0].contains("16 GB"))
    }

    func testNotEnoughDiskIsRefusedWithNumbers() {
        let r = Preflight.evaluate(ramBytes: 32 * gib, freeBytes: 20_000_000_000)
        XCTAssertFalse(r.ok)
        XCTAssertTrue(r.problems[0].contains("20 GB free"))
    }
}

final class SetupStateTests: XCTestCase {
    func testDetectsEachStage() throws {
        let root = tmpDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(appSupport: root.appendingPathComponent("support"), dataDir: root.appendingPathComponent("data"))
        let hub = root.appendingPathComponent("hub")
        let fm = FileManager.default

        XCTAssertEqual(SetupState.detect(paths: paths, hfHub: hub), .needsSetup(reason: "no configuration yet"))

        try fm.createDirectory(at: paths.appSupport, withIntermediateDirectories: true)
        try "backend: mira-mlx\n".write(to: paths.configFile, atomically: true, encoding: .utf8)
        XCTAssertEqual(SetupState.detect(paths: paths, hfHub: hub), .needsSetup(reason: "no model configured"))

        try "model: mlx-community/Some-Model-4bit   # comment\n".write(to: paths.configFile, atomically: true, encoding: .utf8)
        XCTAssertEqual(SetupState.detect(paths: paths, hfHub: hub), .needsSetup(reason: "the model is not downloaded"))

        let snap = hub.appendingPathComponent("models--mlx-community--Some-Model-4bit/snapshots/abc")
        try fm.createDirectory(at: snap, withIntermediateDirectories: true)
        XCTAssertEqual(SetupState.detect(paths: paths, hfHub: hub), .needsSetup(reason: "the model is not downloaded"),
                       "an empty snapshot is a half-finished download")
        try "{}".write(to: snap.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        XCTAssertEqual(SetupState.detect(paths: paths, hfHub: hub), .ready)
    }

    func testALocalModelDirectoryCounts() throws {
        let root = tmpDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = root.appendingPathComponent("My-MTP")
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        XCTAssertFalse(SetupState.modelAvailable(model.path, hfHub: root))
        try "{}".write(to: model.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        XCTAssertTrue(SetupState.modelAvailable(model.path, hfHub: root))
    }

    func testConfigParsingIgnoresCommentedAndIndentedLines() throws {
        let root = tmpDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let f = root.appendingPathComponent("c.yaml")
        try "# model: no\n  model: nested\nmodel: \"yes/this\"  # why\n".write(to: f, atomically: true, encoding: .utf8)
        XCTAssertEqual(ConfigFile.value("model", in: f), "yes/this")
        XCTAssertNil(ConfigFile.value("absent", in: f))
    }

    func testDownloadProgressSumsBlobsAndParsesMTPLines() throws {
        let root = tmpDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let blobs = root.appendingPathComponent("models--a--b/blobs")
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        try Data(count: 1000).write(to: blobs.appendingPathComponent("x"))
        try Data(count: 500).write(to: blobs.appendingPathComponent("y.incomplete"))
        XCTAssertEqual(DownloadProgress.bytesOnDisk(model: "a/b", hfHub: root), 1500)
        XCTAssertEqual(DownloadProgress.bytesOnDisk(model: "no/such", hfHub: root), 0)

        let p = DownloadProgress.parseGBLine("   0.42 / 1.69 GB")
        XCTAssertEqual(p?.done, 0.42)
        XCTAssertEqual(p?.total, 1.69)
        XCTAssertNil(DownloadProgress.parseGBLine("Downloading mlx-community/x"))
    }
}

final class MenuStatusTests: XCTestCase {
    private let ready = SetupState.ready
    private func derive(_ sup: SupervisorState, _ h: HealthSnapshot, setup: SetupState = .ready, running: Bool = false) -> MenuStatus {
        MenuStatus.derive(supervisor: sup, health: h, setup: setup, setupRunning: running)
    }

    func testEngineStatesMapToWhatTheUserSees() {
        XCTAssertEqual(derive(.running(pid: 1), HealthSnapshot(reachable: true, backendReady: true, engineState: .running)).kind, .ready)
        XCTAssertEqual(derive(.running(pid: 1), HealthSnapshot(reachable: true, backendReady: true, engineState: .sleeping)).kind, .asleep)
        XCTAssertEqual(derive(.running(pid: 1), HealthSnapshot(reachable: true, backendReady: false, engineState: .waking)).kind, .waking)
        XCTAssertEqual(derive(.running(pid: 1), HealthSnapshot(reachable: true, backendReady: false)).kind, .loadingModel)
    }

    func testAServerWeDidNotStartIsExternalAndOurs() {
        let up = HealthSnapshot(reachable: true, backendReady: true, engineState: .running)
        XCTAssertTrue(derive(.stopped, up).external)
        XCTAssertFalse(derive(.running(pid: 9), up).external)
    }

    func testStartingStoppedFailedAndSetup() {
        XCTAssertEqual(derive(.running(pid: 1), .unreachable).kind, .starting)
        XCTAssertEqual(derive(.stopped, .unreachable).kind, .stopped)
        XCTAssertEqual(derive(.stopped, .unreachable, setup: .needsSetup(reason: "x")).kind, .needsSetup)
        XCTAssertEqual(derive(.failed("boom"), .unreachable).kind, .failed)
        XCTAssertEqual(derive(.stopped, .unreachable, running: true).kind, .settingUp)
        XCTAssertTrue(derive(.failed("boom"), .unreachable).title.contains("boom"))
    }
}

final class RuntimeLayoutTests: XCTestCase {
    func testBundledLayoutAndEnvironmentKeepWritesOutsideTheBundle() {
        let res = URL(fileURLWithPath: "/Applications/Mira.app/Contents/Resources")
        let layout = RuntimeLayout.bundled(resources: res)
        let paths = AppPaths(appSupport: URL(fileURLWithPath: "/u/Library/Application Support/Mira"), dataDir: URL(fileURLWithPath: "/u/.local/share/mira"))
        let spec = layout.serverSpec(paths: paths, base: ["HOME": "/u"])
        XCTAssertEqual(spec.executable, "/Applications/Mira.app/Contents/Resources/python/bin/python3.13")
        XCTAssertEqual(spec.arguments, ["server.py"])
        XCTAssertEqual(spec.workingDirectory, "/Applications/Mira.app/Contents/Resources/mira-core")
        XCTAssertEqual(spec.environment["PYTHONHOME"], "/Applications/Mira.app/Contents/Resources/python")
        XCTAssertEqual(spec.environment["MIRA_CONFIG"], "/u/Library/Application Support/Mira/mira.yaml")
        XCTAssertEqual(spec.environment["MIRA_DATA_DIR"], "/u/.local/share/mira")
        XCTAssertEqual(spec.environment["PYTHONDONTWRITEBYTECODE"], "1", "writing .pyc would modify the signed bundle")
        XCTAssertEqual(spec.environment["HOME"], "/u")
        XCTAssertEqual(spec.logPath, "/u/Library/Application Support/Mira/logs/server.log")
    }

    func testDevelopmentLayoutUsesTheCheckoutVenv() {
        let l = RuntimeLayout.development(coreDir: "/src/mira-core")
        XCTAssertEqual(l.python, "/src/mira-core/.venv/bin/python")
        XCTAssertNil(l.pythonHome)
        XCTAssertFalse(l.isUsable)
    }
}
