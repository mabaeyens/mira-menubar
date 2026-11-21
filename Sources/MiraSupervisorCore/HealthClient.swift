import Foundation

/// Mirrors mira-core's `engine_state` (docs/engine-lifecycle.md in that repo).
public enum EngineState: String, Equatable, Sendable {
    case running, unloading, sleeping, waking
}

public struct HealthSnapshot: Equatable, Sendable {
    public var reachable: Bool
    public var backendReady: Bool
    /// nil when the server predates the engine lifecycle or idle unload is off.
    public var engineState: EngineState?

    public init(reachable: Bool, backendReady: Bool = false, engineState: EngineState? = nil) {
        self.reachable = reachable
        self.backendReady = backendReady
        self.engineState = engineState
    }

    public static let unreachable = HealthSnapshot(reachable: false)
}

public protocol HealthProviding: Sendable {
    func snapshot() async -> HealthSnapshot
    func wake() async -> Bool
    /// false when the server refuses (busy, or idle unload is off).
    func unload() async -> Bool
}

public struct HealthClient: HealthProviding {
    public var baseURL: URL
    public var session: URLSession
    /// Only needed when mira.yaml sets `auth_token`. /health never needs it.
    public var token: String?

    public init(baseURL: URL = URL(string: "http://127.0.0.1:8000")!, session: URLSession = .shared, token: String? = nil) {
        self.baseURL = baseURL
        self.session = session
        self.token = token
    }

    public func snapshot() async -> HealthSnapshot {
        var req = URLRequest(url: baseURL.appendingPathComponent("health"))
        req.timeoutInterval = 2
        guard let (data, resp) = try? await session.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .unreachable
        }
        return HealthSnapshot(
            reachable: true,
            backendReady: obj["backend_ready"] as? Bool ?? false,
            engineState: (obj["engine_state"] as? String).flatMap(EngineState.init(rawValue:))
        )
    }

    public func wake() async -> Bool { await post("engine/wake", timeout: 300) }
    public func unload() async -> Bool { await post("engine/unload", timeout: 30) }

    private func post(_ path: String, timeout: TimeInterval) async -> Bool {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        guard let (_, resp) = try? await session.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }
}
