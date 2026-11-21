import Foundation

public struct SetupProgress: Equatable, Sendable {
    public var fraction: Double
    public var message: String
    public init(fraction: Double, message: String) {
        self.fraction = fraction
        self.message = message
    }
}

public enum SetupError: Error, Equatable, CustomStringConvertible {
    case preflight([String])
    case step(String, Int32)
    case runtimeMissing

    public var description: String {
        switch self {
        case .preflight(let p): return p.joined(separator: " ")
        case .step(let what, let rc): return "\(what) did not finish (exit \(rc)). See the setup log."
        case .runtimeMissing: return "The bundled runtime is missing or damaged. Reinstall Mira."
        }
    }
}

/// First-run setup. The logic lives in mira-core (`mira_cli.py profile`, `fetch-model`); this
/// only sequences those commands and turns their output into progress, so the app and the
/// command-line installer can never disagree about what "recommended" means.
public final class SetupRunner: @unchecked Sendable {
    private let layout: RuntimeLayout
    private let paths: AppPaths
    private let hfHub: URL
    private let defaultModel = "mlx-community/Qwen3.6-35B-A3B-4bit"

    public init(layout: RuntimeLayout, paths: AppPaths, hfHub: URL = SetupState.defaultHFHub()) {
        self.layout = layout
        self.paths = paths
        self.hfHub = hfHub
    }

    public func run(progress: @escaping @Sendable (SetupProgress) -> Void) async throws {
        guard layout.isUsable else { throw SetupError.runtimeMissing }
        try paths.createDirectories()
        try? FileManager.default.removeItem(at: paths.setupLog)

        let pre = Preflight.currentMachine(freeAt: paths.dataDir)
        guard pre.ok else { throw SetupError.preflight(pre.problems) }

        progress(SetupProgress(fraction: 0.02, message: "Preparing settings"))
        if !FileManager.default.fileExists(atPath: paths.configFile.path) {
            try FileManager.default.copyItem(
                at: URL(fileURLWithPath: layout.coreDir + "/mira.yaml.example"), to: paths.configFile)
        }
        let rc1 = try await runToCompletion(layout.cliSpec(["profile", "recommended"], paths: paths))
        guard rc1 == 0 else { throw SetupError.step("Applying the recommended settings", rc1) }

        let model = ConfigFile.value("model", in: paths.configFile) ?? defaultModel
        var args = ["fetch-model"]
        let wantsMTP = pre.tier == .large && model == defaultModel
        if wantsMTP { args += ["--mtp", "--write-config"] }
        let hfGB = pre.tier == .large ? 19.4 : 8.7

        let poller = Task { [paths, hfHub] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                let log = Self.tail(of: paths.setupLog)
                if wantsMTP, log.contains("Fetching the MTP head"),
                   let line = log.split(whereSeparator: \.isNewline).last(where: { DownloadProgress.parseGBLine(String($0)) != nil }),
                   let (done, total) = DownloadProgress.parseGBLine(String(line)) {
                    progress(SetupProgress(fraction: 0.92 + 0.07 * min(done / total, 1),
                                           message: String(format: "Downloading the speed-up data, %.1f of %.1f GB", done, total)))
                } else {
                    let have = Double(DownloadProgress.bytesOnDisk(model: model, hfHub: hfHub)) / 1e9
                    progress(SetupProgress(fraction: 0.05 + 0.87 * min(have / hfGB, 1),
                                           message: String(format: "Downloading %@, %.1f of %.0f GB", pre.tier.displayName, have, hfGB)))
                }
            }
        }
        defer { poller.cancel() }

        let rc2 = try await runToCompletion(layout.cliSpec(args, paths: paths))
        guard rc2 == 0 else { throw SetupError.step("Downloading the model", rc2) }
        progress(SetupProgress(fraction: 1, message: "Ready"))
    }

    private static func tail(of url: URL, bytes: Int = 4096) -> String {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        try? fh.seek(toOffset: size > UInt64(bytes) ? size - UInt64(bytes) : 0)
        return String(decoding: (try? fh.readToEnd()) ?? Data(), as: UTF8.self)
    }
}
