import XCTest
@testable import MiraSupervisorCore

final class PairingTokenTests: XCTestCase {
    func testTokensAreUnpaddedBase64URLAndNeverRepeat() throws {
        let tokens = try (0..<50).map { _ in try PairingToken.generate() }
        XCTAssertEqual(Set(tokens).count, 50)
        for t in tokens {
            XCTAssertEqual(t.count, 43)
            XCTAssertFalse(t.contains("+") || t.contains("/") || t.contains("="))
        }
    }
}

final class PairingPayloadTests: XCTestCase {
    func testRoundTripKeepsTheTokenInTheFragment() throws {
        let token = try PairingToken.generate()
        let p = PairingPayload(url: URL(string: "https://macbook.tail1234.ts.net:8443")!, label: "Miguel's Mac", token: token)
        XCTAssertTrue(p.link.hasPrefix("mira://pair?u=https%3A%2F%2Fmacbook.tail1234.ts.net%3A8443"))
        XCTAssertTrue(p.link.hasSuffix("#t=" + token))
        XCTAssertFalse(p.link.components(separatedBy: "#")[0].contains(token))  // never in the query
        XCTAssertEqual(PairingPayload.parse(p.link), p)
    }

    func testRejectsWhatIsNotAnHTTPSPairingLinkWithAToken() {
        let ok = "mira://pair?u=https%3A%2F%2Fa.ts.net%3A8443#t=abc_DEF-123"
        XCTAssertNotNil(PairingPayload.parse(ok))
        XCTAssertNil(PairingPayload.parse("mira://pair?u=http%3A%2F%2Fa.ts.net#t=abc"))            // http
        XCTAssertNil(PairingPayload.parse("mira://pair?u=https%3A%2F%2Fa.ts.net"))                  // no token
        XCTAssertNil(PairingPayload.parse("mira://pair?u=https%3A%2F%2Fa.ts.net#t="))               // empty token
        XCTAssertNil(PairingPayload.parse("mira://pair?u=https%3A%2F%2Fa.ts.net#t=a+b/c"))          // standard base64
        XCTAssertNil(PairingPayload.parse("mira://other?u=https%3A%2F%2Fa.ts.net#t=abc"))           // wrong host
        XCTAssertNil(PairingPayload.parse("https://a.ts.net#t=abc"))
        XCTAssertNil(PairingPayload.parse("mira://pair?u=https%3A%2F%2F#t=abc"))                    // no host
    }
}

final class ConfigEditTests: XCTestCase {
    private func temp(_ text: String) -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("cfg-\(UUID().uuidString).yaml")
        try! text.write(to: u, atomically: true, encoding: .utf8)
        return u
    }

    func testSetAddsOrReplacesOnlyItsOwnKeyAndKeepsComments() throws {
        let u = temp("# my config\nbackend: mira-mlx\nmodel: /m  # keep\n")
        try ConfigEdit.set("auth_token", to: "T1", in: u)
        try ConfigEdit.set("auth_token", to: "T2", in: u)
        let text = try String(contentsOf: u, encoding: .utf8)
        XCTAssertEqual(text, "# my config\nbackend: mira-mlx\nmodel: /m  # keep\nauth_token: T2\n")
    }

    func testSetCollapsesDuplicatesAndRemoveTakesOnlyThatKey() throws {
        let u = temp("auth_token: a\nmodel: x\nauth_token: b\n")
        try ConfigEdit.set("auth_token", to: "c", in: u)
        XCTAssertEqual(try String(contentsOf: u, encoding: .utf8), "auth_token: c\nmodel: x\n")
        try ConfigEdit.remove("auth_token", in: u)
        XCTAssertEqual(try String(contentsOf: u, encoding: .utf8), "model: x\n")
    }

    func testBlockListValuesGoWithTheirKeyAndNewlinesAreRefused() throws {
        let u = temp("backend: x\nallowed_hosts:\n  - old.ts.net\n  - other.ts.net\nmodel: /m\n")
        try ConfigEdit.set("allowed_hosts", to: "[\"new.ts.net\"]", in: u)
        XCTAssertEqual(try String(contentsOf: u, encoding: .utf8), "backend: x\nallowed_hosts: [\"new.ts.net\"]\nmodel: /m\n")
        let v = temp("allowed_hosts:\n  - a\nmodel: /m\n")
        try ConfigEdit.remove("allowed_hosts", in: v)
        XCTAssertEqual(try String(contentsOf: v, encoding: .utf8), "model: /m\n")
        XCTAssertThrowsError(try ConfigEdit.set("auth_token", to: "a\nevil: 1", in: u))
    }

    func testTheFileIsOwnerOnlyBecauseItHoldsAToken() throws {
        let u = temp("model: x\n")
        try ConfigEdit.set("auth_token", to: "t", in: u)
        let mode = try FileManager.default.attributesOfItem(atPath: u.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }
}

final class TailscaleStatusTests: XCTestCase {
    func testParsesTheNameWithoutItsTrailingDot() {
        let json = #"{"BackendState":"Running","Self":{"DNSName":"macbook.tail1234.ts.net."}}"#
        XCTAssertEqual(TailscaleStatus.parse(Data(json.utf8)), TailscaleStatus(running: true, dnsName: "macbook.tail1234.ts.net"))
    }
    func testStoppedAndNamelessAreNotRunning() {
        XCTAssertEqual(TailscaleStatus.parse(Data(#"{"BackendState":"Stopped","Self":{"DNSName":""}}"#.utf8)),
                       TailscaleStatus(running: false, dnsName: nil))
        XCTAssertNil(TailscaleStatus.parse(Data("not json".utf8)))
    }
}

private struct FakeTailscale: TailscaleCLI {
    var result: Result<TailscaleStatus, RemoteAccessError>
    var certFails = false
    func status() async throws -> TailscaleStatus { try result.get() }
    func issueCertificate(host: String, certPath: String, keyPath: String) async throws {
        if certFails { throw RemoteAccessError.certificateFailed("HTTPS is not enabled") }
        try "CERT \(host)".write(toFile: certPath, atomically: true, encoding: .utf8)
        try "KEY".write(toFile: keyPath, atomically: true, encoding: .utf8)
    }
}

final class RemoteAccessTests: XCTestCase {
    private func paths() -> AppPaths {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("ra-\(UUID().uuidString)")
        let p = AppPaths.standard(home: home)
        try? p.createDirectories()
        try? "backend: mira-mlx\nmodel: /m\n".write(to: p.configFile, atomically: true, encoding: .utf8)
        return p
    }
    private let up = FakeTailscale(result: .success(TailscaleStatus(running: true, dnsName: "mac.tail1.ts.net")))

    func testOffByDefaultThenOnWithATokenHostAndCertificate() async throws {
        let ra = RemoteAccess(paths: paths())
        XCTAssertFalse(ra.isEnabled)
        XCTAssertNil(ra.payload())
        try await ra.enable(using: up)
        XCTAssertTrue(ra.isEnabled)
        XCTAssertEqual(ra.host, "mac.tail1.ts.net")
        XCTAssertEqual(ra.payload(label: "Mac")?.url.absoluteString, "https://mac.tail1.ts.net:8443")
        XCTAssertEqual(ra.payload()?.token.count, 43)
    }

    func testEnablingAgainKeepsTheExistingToken() async throws {
        let ra = RemoteAccess(paths: paths())
        try await ra.enable(using: up)
        let first = ra.token
        try await ra.enable(using: up)
        XCTAssertEqual(ra.token, first)
    }

    func testRotateChangesTheTokenAndDisableRestoresLoopbackOnly() async throws {
        let p = paths()
        let ra = RemoteAccess(paths: p)
        try await ra.enable(using: up)
        let before = ra.token
        try ra.rotateToken()
        XCTAssertNotEqual(ra.token, before)
        try ra.disable()
        XCTAssertFalse(ra.isEnabled)
        XCTAssertNil(ra.token)
        XCTAssertEqual(try String(contentsOf: p.configFile, encoding: .utf8), "backend: mira-mlx\nmodel: /m\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: p.certFile.path))
    }

    func testRefusesWithoutTailscaleAndChangesNothing() async throws {
        for (fake, expected) in [
            (FakeTailscale(result: .failure(.tailscaleMissing)), RemoteAccessError.tailscaleMissing),
            (FakeTailscale(result: .success(TailscaleStatus(running: false, dnsName: nil))), .tailscaleNotRunning),
            (FakeTailscale(result: .success(TailscaleStatus(running: true, dnsName: nil))), .noMagicDNSName),
        ] {
            let p = paths()
            do { try await RemoteAccess(paths: p).enable(using: fake); XCTFail("should refuse") }
            catch { XCTAssertEqual(error as? RemoteAccessError, expected) }
            XCTAssertEqual(try String(contentsOf: p.configFile, encoding: .utf8), "backend: mira-mlx\nmodel: /m\n")
        }
    }

    func testACertificateFailureLeavesNoTokenBehind() async throws {
        let p = paths()
        let fake = FakeTailscale(result: .success(TailscaleStatus(running: true, dnsName: "mac.tail1.ts.net")), certFails: true)
        do { try await RemoteAccess(paths: p).enable(using: fake); XCTFail("should fail") } catch {}
        XCTAssertNil(RemoteAccess(paths: p).token)
    }

    func testServerGetsTheCertificateOnlyWhenRemoteAccessIsOn() async throws {
        let p = paths()
        let layout = RuntimeLayout(python: "/p", pythonHome: nil, pythonPath: [], coreDir: "/c")
        XCTAssertNil(layout.serverSpec(paths: p, base: [:]).environment["SSL_CERTFILE"])
        try await RemoteAccess(paths: p).enable(using: up)
        let env = layout.serverSpec(paths: p, base: [:]).environment
        XCTAssertEqual(env["SSL_CERTFILE"], p.certFile.path)
        XCTAssertEqual(env["SSL_KEYFILE"], p.keyFile.path)
    }

    func testAHostileTailscaleNameIsRefusedBeforeAnythingIsWritten() async throws {
        let p = paths()
        for bad in ["a\"]\nauth_token: x", "-flag.ts.net", "has space.ts.net", ""] {
            let fake = FakeTailscale(result: .success(TailscaleStatus(running: true, dnsName: bad)))
            do { try await RemoteAccess(paths: p).enable(using: fake); XCTFail("accepted \(bad)") } catch {}
        }
        XCTAssertNil(RemoteAccess(paths: p).token)
    }

    func testInheritedCertificateVariablesAreDroppedWhenRemoteAccessIsOff() {
        let layout = RuntimeLayout(python: "/p", pythonHome: nil, pythonPath: [], coreDir: "/c")
        let env = layout.serverSpec(paths: paths(), base: ["SSL_CERTFILE": "/x", "SSL_KEYFILE": "/y"]).environment
        XCTAssertNil(env["SSL_CERTFILE"])
        XCTAssertNil(env["SSL_KEYFILE"])
    }

    func testCertificateRenewalIsDueAfterSixtyDays() async throws {
        let p = paths()
        let ra = RemoteAccess(paths: p)
        try await ra.enable(using: up)
        XCTAssertFalse(ra.certificateNeedsRenewal())
        XCTAssertTrue(ra.certificateNeedsRenewal(now: Date().addingTimeInterval(61 * 24 * 3600)))
    }
}

/// Uses the real `tailscale` CLI of the machine running the tests. Off unless MIRA_LIVE_TAILSCALE=1,
/// and it only ever writes under a temporary home, never the real Application Support folder.
final class LiveTailscaleTests: XCTestCase {
    func testEnableAndDisableAgainstTheRealTailscale() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MIRA_LIVE_TAILSCALE"] == "1")
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("live-\(UUID().uuidString)")
        let p = AppPaths.standard(home: home)
        try p.createDirectories()
        try "backend: mira-mlx\n".write(to: p.configFile, atomically: true, encoding: .utf8)
        let ra = RemoteAccess(paths: p)
        try await ra.enable(using: SystemTailscale())
        XCTAssertTrue(ra.isEnabled)
        let payload = try XCTUnwrap(ra.payload(label: "test"))
        XCTAssertTrue(payload.url.host?.hasSuffix(".ts.net") == true, "host was \(payload.url.host ?? "nil")")
        XCTAssertEqual(payload.url.port, 8443)
        XCTAssertEqual(PairingPayload.parse(payload.link), payload)
        let certText = try String(contentsOf: p.certFile, encoding: .utf8)
        XCTAssertTrue(certText.contains("BEGIN CERTIFICATE"))
        let keyMode = try FileManager.default.attributesOfItem(atPath: p.keyFile.path)[.posixPermissions] as? Int
        XCTAssertEqual(keyMode, 0o600)
        try ra.disable()
        XCTAssertFalse(ra.isEnabled)
        try? FileManager.default.removeItem(at: home)
    }
}
