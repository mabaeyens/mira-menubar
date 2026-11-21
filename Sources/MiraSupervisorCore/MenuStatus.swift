import Foundation

/// What the menu shows. Derived, never stored: one function from the facts we can observe.
public struct MenuStatus: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case needsSetup, settingUp, starting, loadingModel, ready, asleep, waking, stopping, stopped, failed
    }

    public var kind: Kind
    /// The server was started by something else (the command-line install). We watch it
    /// and never stop or restart it.
    public var external: Bool
    public var detail: String?

    public init(kind: Kind, external: Bool, detail: String? = nil) {
        self.kind = kind
        self.external = external
        self.detail = detail
    }

    public var title: String {
        switch kind {
        case .needsSetup: return "Set up Mira"
        case .settingUp: return detail ?? "Setting up"
        case .starting: return "Starting"
        case .loadingModel: return "Loading the model"
        case .ready: return "Ready"
        case .asleep: return "Asleep. Wakes when you send a message"
        case .waking: return "Waking up"
        case .stopping: return "Stopping"
        case .stopped: return "Stopped"
        case .failed: return detail.map { "Problem: \($0)" } ?? "Problem"
        }
    }

    public var symbol: String {
        switch kind {
        case .ready: return "bubble.left.fill"
        case .asleep: return "moon.zzz.fill"
        case .starting, .loadingModel, .waking: return "arrow.triangle.2.circlepath"
        case .settingUp: return "arrow.down.circle.fill"
        case .needsSetup: return "arrow.down.circle"
        case .stopped, .stopping: return "stop.circle"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    public static func derive(supervisor: SupervisorState, health: HealthSnapshot, setup: SetupState,
                              setupRunning: Bool = false, setupDetail: String? = nil) -> MenuStatus {
        if setupRunning { return MenuStatus(kind: .settingUp, external: false, detail: setupDetail) }

        let startedByUs: Bool
        switch supervisor {
        case .running, .starting, .stopping: startedByUs = true
        default: startedByUs = false
        }

        if health.reachable {
            let k: Kind
            switch health.engineState {
            case .sleeping: k = .asleep
            case .waking, .unloading: k = .waking
            default: k = health.backendReady ? .ready : .loadingModel
            }
            return MenuStatus(kind: k, external: !startedByUs)
        }

        switch supervisor {
        case .failed(let msg): return MenuStatus(kind: .failed, external: false, detail: msg)
        case .stopping: return MenuStatus(kind: .stopping, external: false)
        case .starting, .running: return MenuStatus(kind: .starting, external: false)
        case .stopped:
            if case .needsSetup = setup { return MenuStatus(kind: .needsSetup, external: false) }
            return MenuStatus(kind: .stopped, external: false)
        }
    }
}
