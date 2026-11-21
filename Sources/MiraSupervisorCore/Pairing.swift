import Foundation
import Security

// MARK: - Token

public enum PairingToken {
    public enum TokenError: Error { case noRandomness }

    /// 32 bytes from the system CSPRNG, as unpadded base64url (43 characters).
    public static func generate(bytes: Int = 32) throws -> String {
        var buffer = [UInt8](repeating: 0, count: bytes)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes, &buffer) == errSecSuccess else { throw TokenError.noRandomness }
        return base64url(Data(buffer))
    }

    public static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func isBase64URL(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "=") }
    }
}

// MARK: - Pairing link

/// `mira://pair?u=<percent-encoded https url>&n=<label>#t=<token>`
///
/// The token travels in the fragment, never the query: a fragment is not sent in a request and
/// is far less likely to end up in a log. The same string is what a QR code will carry. The
/// mira-apps session parses exactly this format, so do not change it without telling it.
public struct PairingPayload: Equatable, Sendable {
    public var url: URL
    public var label: String?
    public var token: String

    public init(url: URL, label: String? = nil, token: String) {
        self.url = url
        self.label = label
        self.token = token
    }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func encode(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "" }

    public var link: String {
        var out = "mira://pair?u=" + Self.encode(url.absoluteString)
        if let label, !label.isEmpty { out += "&n=" + Self.encode(label) }
        return out + "#t=" + token
    }

    /// Returns nil for anything that is not https, not `mira://pair`, or has no usable token.
    public static func parse(_ text: String) -> PairingPayload? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.hasPrefix("mira://pair?"), let hash = s.firstIndex(of: "#") else { return nil }
        let query = String(s[s.index(s.startIndex, offsetBy: "mira://pair?".count)..<hash])
        let fragment = String(s[s.index(after: hash)...])
        guard fragment.hasPrefix("t=") else { return nil }
        let token = String(fragment.dropFirst(2))
        guard PairingToken.isBase64URL(token) else { return nil }

        var urlString: String?
        var label: String?
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2, let value = kv[1].removingPercentEncoding else { continue }
            if kv[0] == "u" { urlString = value } else if kv[0] == "n" { label = value }
        }
        guard let urlString, let url = URL(string: urlString), url.scheme == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return PairingPayload(url: url, label: label, token: token)
    }
}

// MARK: - mira.yaml edits

/// Line-based edits of flat top-level keys. Comments, ordering and every other key are left alone.
public enum ConfigEdit {
    public static func set(_ key: String, to value: String, in url: URL) throws {
        var lines = read(url)
        let line = "\(key): \(value)"
        if let first = lines.firstIndex(where: { $0.hasPrefix(key + ":") }) {
            lines[first] = line
            var i = lines.count - 1
            while i > first {  // drop duplicates of the same key
                if lines[i].hasPrefix(key + ":") { lines.remove(at: i) }
                i -= 1
            }
        } else {
            lines.append(line)
        }
        try write(lines, to: url)
    }

    public static func remove(_ key: String, in url: URL) throws {
        try write(read(url).filter { !$0.hasPrefix(key + ":") }, to: url)
    }

    private static func read(_ url: URL) -> [String] {
        var lines = ((try? String(contentsOf: url, encoding: .utf8)) ?? "").components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    /// The file holds a bearer token, so it is written 0600 whether or not it existed.
    private static func write(_ lines: [String], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = lines.joined(separator: "\n") + "\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

// MARK: - Tailscale

public struct TailscaleStatus: Equatable, Sendable {
    public var running: Bool
    public var dnsName: String?
    public init(running: Bool, dnsName: String?) {
        self.running = running
        self.dnsName = dnsName
    }

    /// From `tailscale status --json`: `BackendState` and `Self.DNSName` (trailing dot removed).
    public static func parse(_ data: Data) -> TailscaleStatus? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let running = (obj["BackendState"] as? String) == "Running"
        var name = (obj["Self"] as? [String: Any])?["DNSName"] as? String
        if name?.hasSuffix(".") == true { name?.removeLast() }
        if name?.isEmpty == true { name = nil }
        return TailscaleStatus(running: running, dnsName: name)
    }
}

public enum RemoteAccessError: Error, Equatable, CustomStringConvertible {
    case tailscaleMissing
    case tailscaleNotRunning
    case noMagicDNSName
    case certificateFailed(String)
    case notEnabled

    public var description: String {
        switch self {
        case .tailscaleMissing: return "Tailscale is not installed. Remote access works over Tailscale only."
        case .tailscaleNotRunning: return "Tailscale is not connected. Open Tailscale, sign in, then try again."
        case .noMagicDNSName: return "This Mac has no Tailscale name. Turn on MagicDNS in the Tailscale admin console."
        case .certificateFailed(let why):
            return "Tailscale could not issue an HTTPS certificate: \(why). Turn on HTTPS certificates for your tailnet."
        case .notEnabled: return "Remote access is off."
        }
    }
}

public protocol TailscaleCLI: Sendable {
    func status() async throws -> TailscaleStatus
    func issueCertificate(host: String, certPath: String, keyPath: String) async throws
}

/// The real `tailscale` command line. Arguments are passed as a list, never through a shell.
public struct SystemTailscale: TailscaleCLI {
    static let candidates = ["/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale",
                             "/Applications/Tailscale.app/Contents/MacOS/Tailscale"]

    public init() {}

    static func locate() -> String? { candidates.first { FileManager.default.isExecutableFile(atPath: $0) } }

    public func status() async throws -> TailscaleStatus {
        guard let exe = Self.locate() else { throw RemoteAccessError.tailscaleMissing }
        let (code, out) = try await Self.run(exe, ["status", "--json"], timeout: 15)
        guard code == 0, let status = TailscaleStatus.parse(out) else { throw RemoteAccessError.tailscaleNotRunning }
        return status
    }

    public func issueCertificate(host: String, certPath: String, keyPath: String) async throws {
        guard let exe = Self.locate() else { throw RemoteAccessError.tailscaleMissing }
        let (code, out) = try await Self.run(exe, ["cert", "--cert-file", certPath, "--key-file", keyPath, host], timeout: 90)
        guard code == 0 else {
            let msg = String(data: out, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw RemoteAccessError.certificateFailed(msg.isEmpty ? "exit \(code)" : String(msg.prefix(200)))
        }
    }

    static func run(_ exe: String, _ args: [String], timeout: TimeInterval) async throws -> (Int32, Data) {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = args
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = pipe
                do { try p.run() } catch { cont.resume(throwing: error); return }
                let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                killer.cancel()
                cont.resume(returning: (p.terminationStatus, data))
            }
        }
    }
}

// MARK: - Remote access

/// Remote access is opt-in. Off, the server is loopback-only with no token. On, it has a bearer
/// token, accepts the Tailscale name as a Host, and serves HTTPS on :8443 with a Tailscale
/// certificate. There is deliberately no LAN or plain-http mode.
public struct RemoteAccess: Sendable {
    public let paths: AppPaths
    public init(paths: AppPaths) { self.paths = paths }

    /// Tailscale certificates last 90 days and are not renewed on their own.
    public static let renewAfter: TimeInterval = 60 * 24 * 3600

    public var token: String? { ConfigFile.value("auth_token", in: paths.configFile) }

    public var host: String? {
        guard let raw = ConfigFile.value("allowed_hosts", in: paths.configFile) else { return nil }
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "[] \"'"))
        return trimmed.isEmpty ? nil : trimmed.components(separatedBy: ",").first?.trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
    }

    public var isEnabled: Bool {
        token != nil && host != nil
            && FileManager.default.fileExists(atPath: paths.certFile.path)
            && FileManager.default.fileExists(atPath: paths.keyFile.path)
    }

    public func payload(label: String? = nil) -> PairingPayload? {
        guard isEnabled, let token, let host, let url = URL(string: "https://\(host):8443") else { return nil }
        return PairingPayload(url: url, label: label, token: token)
    }

    public func enable(using tailscale: TailscaleCLI) async throws {
        let status = try await tailscale.status()
        guard status.running else { throw RemoteAccessError.tailscaleNotRunning }
        guard let name = status.dnsName else { throw RemoteAccessError.noMagicDNSName }
        try await issueCertificate(host: name, using: tailscale)
        let tokenValue = try token ?? PairingToken.generate()  // an existing token is kept, not replaced
        try ConfigEdit.set("auth_token", to: tokenValue, in: paths.configFile)
        try ConfigEdit.set("allowed_hosts", to: "[\"\(name)\"]", in: paths.configFile)
    }

    public func disable() throws {
        try ConfigEdit.remove("auth_token", in: paths.configFile)
        try ConfigEdit.remove("allowed_hosts", in: paths.configFile)
        for f in [paths.certFile, paths.keyFile] { try? FileManager.default.removeItem(at: f) }
    }

    /// A new token invalidates every paired device.
    public func rotateToken() throws {
        guard isEnabled else { throw RemoteAccessError.notEnabled }
        try ConfigEdit.set("auth_token", to: try PairingToken.generate(), in: paths.configFile)
    }

    public func certificateNeedsRenewal(now: Date = Date()) -> Bool {
        guard isEnabled,
              let modified = try? FileManager.default.attributesOfItem(atPath: paths.certFile.path)[.modificationDate] as? Date
        else { return false }
        return now.timeIntervalSince(modified) > Self.renewAfter
    }

    public func renewCertificate(using tailscale: TailscaleCLI) async throws {
        guard let host else { throw RemoteAccessError.notEnabled }
        try await issueCertificate(host: host, using: tailscale)
    }

    private func issueCertificate(host: String, using tailscale: TailscaleCLI) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: paths.certsDir, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try await tailscale.issueCertificate(host: host, certPath: paths.certFile.path, keyPath: paths.keyFile.path)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.keyFile.path)
    }
}
