import AppKit
import Sparkle
import MiraSupervisorCore

/// In-app updates through Sparkle. Active only inside the built app: the feed URL and the
/// EdDSA public key live in Info.plist, which a `swift run` development binary does not have,
/// so Sparkle is simply not started there.
///
/// The update is trusted by its EdDSA signature plus the Developer ID code signature of the
/// new bundle (Sparkle checks both). Quitting for the swap goes through
/// `applicationShouldTerminate`, which stops the server we started before the bundle is replaced.
@MainActor
final class UpdateController {
    static let shared = UpdateController()

    private let delegate = UpdateDelegate()
    private let controller: SPUStandardUpdaterController?

    private init() {
        if Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil {
            controller = SPUStandardUpdaterController(
                startingUpdater: true, updaterDelegate: delegate, userDriverDelegate: nil)
        } else {
            controller = nil
        }
    }

    var isAvailable: Bool { controller != nil }

    func start() { _ = controller }  // touching the shared instance starts the updater

    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)  // an accessory app is not frontmost by default
        controller?.checkForUpdates(nil)
    }
}

final class UpdateDelegate: NSObject, SPUUpdaterDelegate {
    /// Never update while the first-run model download is in progress.
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        let settingUp = MainActor.assumeIsolated { AppModel.shared.status.kind == .settingUp }
        if settingUp {
            throw NSError(domain: "MiraUpdate", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Setup is in progress; updating later."])
        }
    }
}
