import AppKit
import Foundation
import MiraSupervisorCore
import ServiceManagement

/// Owns the supervisor, polls health, and exposes one derived status to the views.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published private(set) var status = MenuStatus(kind: .stopped, external: false)
    @Published private(set) var health = HealthSnapshot.unreachable
    @Published private(set) var setupProgress: SetupProgress?
    @Published private(set) var setupError: String?
    @Published private(set) var preflight: PreflightResult?
    @Published private(set) var launchAtLogin = false
    @Published private(set) var runtimeProblem: String?

    let paths = AppPaths.standard()
    let serverURL = URL(string: "http://127.0.0.1:8000")!
    private let layout: RuntimeLayout?
    private let supervisor: ServerSupervisor?
    private var supervisorState = SupervisorState.stopped
    private var setupTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var setupWindow: SetupWindowController?
    private var pairingWindow: PairingWindowController?
    private let tailscale: TailscaleCLI = SystemTailscale()
    @Published private(set) var pairing = PairingState()

    private init() {
        layout = Self.discoverRuntime()
        if let layout {
            supervisor = ServerSupervisor(specProvider: { layout.serverSpec(paths: AppPaths.standard()) })
            runtimeProblem = nil
        } else {
            supervisor = nil
            runtimeProblem = "The Mira runtime was not found. Reinstall the app, or set MIRA_CORE_DIR for development."
        }
        launchAtLogin = LoginItem.isEnabled
        supervisor?.observe { [weak self] s in
            Task { @MainActor in
                self?.supervisorState = s
                self?.recompute()
            }
        }
    }

    /// The runtime inside the app bundle, or a mira-core checkout named by MIRA_CORE_DIR.
    static func discoverRuntime() -> RuntimeLayout? {
        if Bundle.main.bundlePath.hasSuffix(".app"), let res = Bundle.main.resourceURL {
            let l = RuntimeLayout.bundled(resources: res)
            if l.isUsable { return l }
        }
        let env = ProcessInfo.processInfo.environment
        if let core = env["MIRA_CORE_DIR"] {
            let l = RuntimeLayout.development(coreDir: core, python: env["MIRA_PYTHON"])
            if l.isUsable { return l }
        }
        return nil
    }

    private var client: HealthClient {
        HealthClient(baseURL: serverURL, token: ConfigFile.value("auth_token", in: paths.configFile))
    }

    // MARK: - lifecycle

    /// Called once at launch. Adopts a server that is already running, otherwise starts one,
    /// otherwise walks the user through setup.
    func launch() {
        try? paths.createDirectories()
        startPolling()
        startCertificateWatch()
        Task {
            let first = await client.snapshot()
            health = first
            recompute()
            if first.reachable { return }  // started elsewhere: watch it, never touch it
            if layout == nil { return }
            switch SetupState.detect(paths: paths) {
            case .ready:
                await renewCertificateIfDue()  // before the server reads the certificate
                startServer()
            case .needsSetup: showSetup()
            }
        }
    }

    /// Stop what we started. Does nothing to a server started elsewhere. Blocks the calling
    /// (main) thread until the process group is gone, or the timeout passes. It must not rely
    /// on a main-actor task to finish: while AppKit is inside `terminate:` it runs its own
    /// run loop mode, and a pending main-actor task never gets to run (found by launching the
    /// notarized build and sending it SIGTERM: it hung forever).
    func shutdownBlocking(timeout: TimeInterval = 20) {
        pollTask?.cancel()
        setupTask?.cancel()
        guard let sup = supervisor else { return }
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            await sup.stop()
            done.signal()
        }
        _ = done.wait(timeout: .now() + timeout)
    }

    var ownsServer: Bool {
        switch supervisorState {
        case .running, .starting, .stopping: return true
        default: return false
        }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let snap = await self.client.snapshot()
                self.health = snap
                self.recompute()
                let fast = !snap.reachable || !snap.backendReady
                try? await Task.sleep(nanoseconds: fast ? 1_000_000_000 : 4_000_000_000)
            }
        }
    }

    private func recompute() {
        status = MenuStatus.derive(
            supervisor: supervisorState, health: health, setup: SetupState.detect(paths: paths),
            setupRunning: setupTask != nil, setupDetail: setupProgress?.message)
    }

    // MARK: - actions

    func startServer() {
        guard !status.external else { return }
        supervisor?.start()
    }

    func stopServer() {
        guard !status.external else { return }
        Task { await supervisor?.stop() }
    }

    func restartServer() {
        guard !status.external else { return }
        Task { await supervisor?.restart() }
    }

    func wakeEngine() { Task { _ = await client.wake() } }
    func unloadEngine() { Task { _ = await client.unload() } }

    func openMira() { NSWorkspace.shared.open(serverURL) }

    func revealLogs() { NSWorkspace.shared.open(paths.logsDir) }

    func setLaunchAtLogin(_ on: Bool) {
        LoginItem.setEnabled(on)
        launchAtLogin = LoginItem.isEnabled
    }

    // MARK: - remote access and pairing

    struct PairingState {
        var enabled = false
        var payload: PairingPayload?
        var busy = false
        var message: String?
    }

    func showPairing() {
        refreshPairing()
        if pairingWindow == nil { pairingWindow = PairingWindowController(model: self) }
        pairingWindow?.show()
    }

    private func refreshPairing() {
        let remote = RemoteAccess(paths: paths)
        pairing.enabled = remote.isEnabled
        pairing.payload = remote.payload(label: Host.current().localizedName)
    }

    /// Whether this app may change the server's configuration. A server started elsewhere keeps its own.
    private var canEditServerConfig: Bool { !status.external && runtimeProblem == nil }

    func setRemoteAccess(_ on: Bool) {
        guard canEditServerConfig else {
            pairing.message = "This server was started outside the app, so the app will not change its settings."
            return
        }
        change { remote in
            if on { try await remote.enable(using: self.tailscale) } else { try remote.disable() }
        }
    }

    func newPairingToken() {
        guard canEditServerConfig else { return }
        change { try $0.rotateToken() }
    }

    /// Runs a configuration change, then restarts the server so it takes effect.
    private func change(_ work: @escaping (RemoteAccess) async throws -> Void) {
        pairing.busy = true
        pairing.message = nil
        Task {
            do {
                try await work(RemoteAccess(paths: paths))
                if ownsServer { await supervisor?.restart() }
            } catch {
                pairing.message = (error as? RemoteAccessError)?.description ?? error.localizedDescription
            }
            pairing.busy = false
            refreshPairing()
        }
    }

    /// Tailscale certificates last 90 days and nothing renews them on its own. Renew at 60 days.
    /// A failure (Tailscale down) is retried at the next check; the old certificate stays in use.
    private func renewCertificateIfDue() async {
        let remote = RemoteAccess(paths: paths)
        guard canEditServerConfig, remote.certificateNeedsRenewal() else { return }
        do {
            try await remote.renewCertificate(using: tailscale)
            if ownsServer { await supervisor?.restart() }  // the server reads the certificate at start
        } catch {
            NSLog("Mira: certificate renewal failed: %@", String(describing: error))
        }
    }

    private func startCertificateWatch() {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 12 * 3600 * 1_000_000_000)
                await self?.renewCertificateIfDue()
            }
        }
    }

    /// The token is on the clipboard only briefly: cleared after a minute unless something else was copied.
    func copyToPasteboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        // Well-behaved clipboard managers skip items marked concealed or transient.
        pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        let count = pb.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            if NSPasteboard.general.changeCount == count { NSPasteboard.general.clearContents() }
        }
    }

    // MARK: - setup

    func showSetup() {
        preflight = Preflight.currentMachine(freeAt: AppPaths.userHome)
        if setupWindow == nil { setupWindow = SetupWindowController(model: self) }
        setupWindow?.show()
    }

    func beginSetup() {
        guard let layout, setupTask == nil else { return }
        setupError = nil
        setupProgress = SetupProgress(fraction: 0, message: "Starting")
        let runner = SetupRunner(layout: layout, paths: paths)
        setupTask = Task { [weak self] in
            do {
                try await runner.run { p in Task { @MainActor in self?.setupProgress = p; self?.recompute() } }
                await MainActor.run {
                    self?.setupTask = nil
                    self?.setupProgress = nil
                    self?.setupWindow?.close()
                    self?.recompute()
                    self?.startServer()
                }
            } catch is CancellationError {
                await MainActor.run { self?.setupTask = nil; self?.setupProgress = nil; self?.recompute() }
            } catch {
                await MainActor.run {
                    self?.setupError = "\(error)"
                    self?.setupTask = nil
                    self?.setupProgress = nil
                    self?.recompute()
                }
            }
        }
        recompute()
    }

    func cancelSetup() {
        setupTask?.cancel()
    }
}

enum LoginItem {
    static var isEnabled: Bool {
        guard Bundle.main.bundlePath.hasSuffix(".app") else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ on: Bool) {
        guard Bundle.main.bundlePath.hasSuffix(".app") else { return }
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("login item change failed: \(error)")
        }
    }
}
