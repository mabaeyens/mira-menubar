import Foundation

/// Where things live on disk. Everything writable is outside the app bundle (which is
/// read-only in /Applications and must stay byte-identical so its signature holds).
public struct AppPaths: Equatable, Sendable {
    public var appSupport: URL
    public var dataDir: URL
    /// The home these paths were built from. Differs from the real home only in an isolated run.
    public var home: URL

    public init(appSupport: URL, dataDir: URL, home: URL = AppPaths.userHome) {
        self.appSupport = appSupport
        self.dataDir = dataDir
        self.home = home
    }

    /// The real home, or the directory named by `MIRA_MENUBAR_HOME`. The app resolves the home
    /// from the account database and ignores `HOME`, so a test run would otherwise write into the
    /// real `~/Library/Application Support/Mira`. Setting this makes a run touch nothing real.
    public static var userHome: URL {
        if let override = ProcessInfo.processInfo.environment["MIRA_MENUBAR_HOME"], override.hasPrefix("/") {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    public var isIsolated: Bool { home.path != FileManager.default.homeDirectoryForCurrentUser.path }

    public static func standard(home: URL = AppPaths.userHome) -> AppPaths {
        AppPaths(
            appSupport: home.appendingPathComponent("Library/Application Support/Mira"),
            // Same default as mira-core, so a model and conversations from another install carry over.
            dataDir: home.appendingPathComponent(".local/share/mira"),
            home: home
        )
    }

    public var configFile: URL { appSupport.appendingPathComponent("mira.yaml") }
    public var logsDir: URL { appSupport.appendingPathComponent("logs") }
    public var serverLog: URL { logsDir.appendingPathComponent("server.log") }
    public var setupLog: URL { logsDir.appendingPathComponent("setup.log") }

    public func createDirectories() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: logsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: dataDir, withIntermediateDirectories: true)
    }
}

/// The Python runtime plus the mira-core source to run. Two shapes: the bundled one inside
/// Mira.app, and a development one pointing at a checkout.
public struct RuntimeLayout: Equatable, Sendable {
    public var python: String
    public var pythonHome: String?
    public var pythonPath: [String]
    public var coreDir: String

    public init(python: String, pythonHome: String?, pythonPath: [String], coreDir: String) {
        self.python = python
        self.pythonHome = pythonHome
        self.pythonPath = pythonPath
        self.coreDir = coreDir
    }

    /// The layout `scripts/build-app.sh` produces under `Contents/Resources`.
    public static func bundled(resources: URL) -> RuntimeLayout {
        let r = resources.path
        return RuntimeLayout(
            python: r + "/python/bin/python3.13",
            pythonHome: r + "/python",
            pythonPath: [r + "/site-packages", r + "/mira-core"],
            coreDir: r + "/mira-core"
        )
    }

    /// A mira-core checkout with its own virtualenv (development).
    public static func development(coreDir: String, python: String? = nil) -> RuntimeLayout {
        RuntimeLayout(python: python ?? coreDir + "/.venv/bin/python", pythonHome: nil, pythonPath: [], coreDir: coreDir)
    }

    public var isUsable: Bool {
        FileManager.default.isExecutableFile(atPath: python)
            && FileManager.default.fileExists(atPath: coreDir + "/server.py")
    }

    func environment(paths: AppPaths, base: [String: String]) -> [String: String] {
        var env = base
        if let home = pythonHome { env["PYTHONHOME"] = home }
        if !pythonPath.isEmpty { env["PYTHONPATH"] = pythonPath.joined(separator: ":") }
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        env["PYTHONUNBUFFERED"] = "1"
        env["MIRA_CONFIG"] = paths.configFile.path
        env["MIRA_DATA_DIR"] = paths.dataDir.path
        if paths.isIsolated {  // keep the child, and its Hugging Face cache, out of the real home too
            env["HOME"] = paths.home.path
            env["HF_HOME"] = paths.home.appendingPathComponent(".cache/huggingface").path
        }
        return env
    }

    /// `python server.py`
    public func serverSpec(paths: AppPaths, base: [String: String] = ProcessInfo.processInfo.environment) -> SpawnSpec {
        SpawnSpec(executable: python, arguments: ["server.py"], environment: environment(paths: paths, base: base),
                  workingDirectory: coreDir, logPath: paths.serverLog.path)
    }

    /// `python mira_cli.py <args>`, for first-run setup.
    public func cliSpec(_ args: [String], paths: AppPaths, log: URL? = nil,
                        base: [String: String] = ProcessInfo.processInfo.environment) -> SpawnSpec {
        SpawnSpec(executable: python, arguments: ["mira_cli.py"] + args,
                  environment: environment(paths: paths, base: base), workingDirectory: coreDir,
                  logPath: (log ?? paths.setupLog).path)
    }
}
