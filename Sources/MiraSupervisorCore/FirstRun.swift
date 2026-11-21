import Foundation

/// Which model a Mac can run. Mirrors `mira profile recommended` in mira-core, so the app's
/// pre-checks and the profile the installer writes agree.
public enum ModelTier: Equatable, Sendable {
    /// Qwen3.6-35B-A3B 4-bit with the MTP head. 31 GiB RAM or more.
    case large
    /// A 14B dense model that fits a 16 to 30 GiB Mac.
    case small

    public var approxDownloadGB: Double { self == .large ? 21.1 : 8.7 }
    public var displayName: String { self == .large ? "Qwen3.6 35B (MTP)" : "Ministral 3 14B" }
}

public struct PreflightResult: Equatable, Sendable {
    public var tier: ModelTier
    public var ok: Bool
    public var problems: [String]
    public var warnings: [String]
    public var requiredFreeGB: Double
}

public enum Preflight {
    static let gib = Double(1 << 30)
    /// Free disk to leave after the download, same headroom the installer uses.
    static let headroomGB = 15.0

    public static func evaluate(ramBytes: UInt64, freeBytes: Int64) -> PreflightResult {
        let ramGiB = Double(ramBytes) / gib
        let freeGB = Double(freeBytes) / 1e9
        let tier: ModelTier = ramGiB >= 31 ? .large : .small
        let required = tier.approxDownloadGB + headroomGB
        var problems: [String] = []
        var warnings: [String] = []

        if ramGiB < 15.5 {
            problems.append("Mira needs at least 16 GB of memory. This Mac has \(Int(ramGiB.rounded())) GB.")
        } else if tier == .small {
            warnings.append("With \(Int(ramGiB.rounded())) GB, Mira uses a smaller model (\(tier.displayName)) so it stays responsive.")
        }
        if freeGB < required {
            problems.append(String(format: "Not enough free disk space: %.0f GB free, about %.0f GB needed (the model is %.0f GB).",
                                   freeGB, required, tier.approxDownloadGB))
        }
        return PreflightResult(tier: tier, ok: problems.isEmpty, problems: problems, warnings: warnings, requiredFreeGB: required)
    }

    public static func currentMachine(freeAt url: URL) -> PreflightResult {
        let free = (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
        return evaluate(ramBytes: ProcessInfo.processInfo.physicalMemory, freeBytes: Int64(free))
    }
}

/// Reads flat top-level `key: value` lines from mira.yaml (the same limited parse mira-core's
/// `mira_cli.py` uses; the file keeps these keys flat on purpose).
public enum ConfigFile {
    public static func value(_ key: String, in url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.hasPrefix(key + ":") else { continue }
            var v = String(line.dropFirst(key.count + 1))
            if let hash = v.firstIndex(of: "#") { v = String(v[..<hash]) }
            v = v.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !v.isEmpty { return v }
        }
        return nil
    }
}

public enum SetupState: Equatable, Sendable {
    case ready
    case needsSetup(reason: String)

    /// Ready when the config exists and the model it names is on disk.
    public static func detect(paths: AppPaths, hfHub: URL = defaultHFHub()) -> SetupState {
        guard FileManager.default.fileExists(atPath: paths.configFile.path) else {
            return .needsSetup(reason: "no configuration yet")
        }
        guard let model = ConfigFile.value("model", in: paths.configFile) else {
            return .needsSetup(reason: "no model configured")
        }
        return modelAvailable(model, hfHub: hfHub) ? .ready : .needsSetup(reason: "the model is not downloaded")
    }

    /// A local model directory, or a populated snapshot in the Hugging Face cache.
    public static func modelAvailable(_ model: String, hfHub: URL) -> Bool {
        let fm = FileManager.default
        if model.hasPrefix("/") || model.hasPrefix("~") || model.hasPrefix(".") {
            let dir = (model as NSString).expandingTildeInPath
            return fm.fileExists(atPath: dir + "/config.json")
        }
        let snaps = hfHub.appendingPathComponent("models--" + model.replacingOccurrences(of: "/", with: "--"))
            .appendingPathComponent("snapshots")
        guard let kids = try? fm.contentsOfDirectory(atPath: snaps.path) else { return false }
        return kids.contains { (try? fm.contentsOfDirectory(atPath: snaps.appendingPathComponent($0).path))?.isEmpty == false }
    }

    public static func defaultHFHub() -> URL {
        if let hf = ProcessInfo.processInfo.environment["HF_HOME"] { return URL(fileURLWithPath: hf).appendingPathComponent("hub") }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/huggingface/hub")
    }
}

/// Bytes already on disk for a model download, so the UI can show a progress bar while
/// `mira fetch-model` (which only prints tqdm bars to a terminal) runs.
public enum DownloadProgress {
    public static func bytesOnDisk(model: String, hfHub: URL) -> Int64 {
        let blobs = hfHub.appendingPathComponent("models--" + model.replacingOccurrences(of: "/", with: "--"))
            .appendingPathComponent("blobs")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: blobs.path) else { return 0 }
        return names.reduce(0) { sum, n in
            let attrs = try? FileManager.default.attributesOfItem(atPath: blobs.appendingPathComponent(n).path)
            return sum + ((attrs?[.size] as? NSNumber)?.int64Value ?? 0)
        }
    }

    /// Parses mira-core's MTP-head progress lines: "  0.42 / 1.69 GB".
    public static func parseGBLine(_ line: String) -> (done: Double, total: Double)? {
        let parts = line.split(separator: "/")
        guard parts.count == 2,
              let done = Double(parts[0].trimmingCharacters(in: .whitespaces).split(separator: " ").last ?? ""),
              let total = Double(parts[1].trimmingCharacters(in: .whitespaces).split(separator: " ").first ?? ""),
              parts[1].contains("GB"), total > 0 else { return nil }
        return (done, total)
    }
}
