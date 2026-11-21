import AppKit
import SwiftUI
import CoreImage.CIFilterBuiltins
import MiraSupervisorCore

struct MenuContent: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Text(model.status.title)
        if model.status.external {
            Text("Started outside this app")
        }
        Divider()

        switch model.status.kind {
        case .needsSetup:
            Button("Set Up Mira…") { model.showSetup() }
        case .settingUp:
            Button("Show Setup Progress") { model.showSetup() }
        default:
            Button("Open Mira") { model.openMira() }
                .disabled(model.health.reachable == false)
        }

        if model.status.kind == .asleep {
            Button("Wake Now") { model.wakeEngine() }
        }
        if model.status.kind == .ready {
            Button("Free Memory Now") { model.unloadEngine() }
        }

        if !model.status.external, model.runtimeProblem == nil {
            Divider()
            if model.ownsServer {
                Button("Restart Server") { model.restartServer() }
                Button("Stop Server") { model.stopServer() }
            } else if model.status.kind != .needsSetup, model.status.kind != .settingUp {
                Button("Start Server") { model.startServer() }
            }
        }

        if let problem = model.runtimeProblem {
            Divider()
            Text(problem)
        }

        Divider()
        if !model.status.external, model.runtimeProblem == nil {
            Button("Pair iPhone…") { model.showPairing() }
        }
        Toggle("Open at Login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
        Button("Show Logs") { model.revealLogs() }
        if UpdateController.shared.isAvailable {
            Button("Check for Updates…") { UpdateController.shared.checkForUpdates() }
        }
        Divider()
        Button("Quit Mira") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

struct SetupView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Set up Mira").font(.title2.bold())
            Text("Mira runs a language model on this Mac. Nothing you write leaves it.")
                .foregroundStyle(.secondary)

            if let pre = model.preflight {
                Label("\(pre.tier.displayName), about \(Int(pre.tier.approxDownloadGB)) GB to download",
                      systemImage: "arrow.down.circle")
                ForEach(pre.warnings, id: \.self) { Label($0, systemImage: "info.circle").foregroundStyle(.secondary) }
                ForEach(pre.problems, id: \.self) { Label($0, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
            }

            if let p = model.setupProgress {
                ProgressView(value: p.fraction)
                Text(p.message).font(.callout).foregroundStyle(.secondary)
            }
            if let err = model.setupError {
                Text(err).foregroundStyle(.red).font(.callout)
            }

            HStack {
                Spacer()
                if model.setupProgress != nil {
                    Button("Cancel") { model.cancelSetup() }
                } else {
                    Button(model.setupError == nil ? "Download and Set Up" : "Try Again") { model.beginSetup() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.preflight?.ok == false)
                }
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}

@MainActor
final class SetupWindowController {
    private var window: NSWindow?
    private let model: AppModel

    init(model: AppModel) { self.model = model }

    func show() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SetupView(model: model)))
            w.title = "Mira"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    func close() { window?.close() }
}

// MARK: - Pairing

struct PairingView: View {
    @ObservedObject var model: AppModel
    @State private var reveal = false

    var body: some View {
        let state = model.pairing
        VStack(alignment: .leading, spacing: 12) {
            Text("Pair iPhone").font(.title2).bold()
            if state.enabled, let payload = state.payload {
                Text("Remote access is on. Mira is reachable only over your Tailscale network, with HTTPS.")
                    .foregroundStyle(.secondary)
                LabeledContent("Address") { Text(payload.url.absoluteString).textSelection(.enabled) }
                LabeledContent("Token") {
                    Text(reveal ? payload.token : String(repeating: "•", count: 16)).textSelection(.enabled)
                        .font(.system(.body, design: .monospaced))
                    Button(reveal ? "Hide" : "Show") { reveal.toggle() }.buttonStyle(.link)
                }
                if reveal, let image = QRCode.image(for: payload.link) {
                    Image(nsImage: image).interpolation(.none).resizable().frame(width: 200, height: 200)
                    Text("Scan with Mira on the iPhone (Add connection, Scan QR).").font(.footnote).foregroundStyle(.secondary)
                }
                Text("On the iPhone, open Mira, add a connection, and paste the link. The token is cleared from the clipboard after a minute.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("Copy Link") { model.copyToPasteboard(payload.link) }.buttonStyle(.borderedProminent)
                    Button("Copy Address") { model.copyToPasteboard(payload.url.absoluteString) }
                    Button("Copy Token") { model.copyToPasteboard(payload.token) }
                }
                Divider()
                HStack {
                    Button("New Token…") { model.newPairingToken() }
                    Button("Turn Off Remote Access") { model.setRemoteAccess(false) }
                }
                Text("A new token stops every paired device until it is paired again.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                Text("Remote access is off. Mira listens on this Mac only, with no token.")
                    .foregroundStyle(.secondary)
                Text("Turning it on needs Tailscale, signed in, with HTTPS certificates enabled for your tailnet. Mira will create a token and a certificate and restart the server. There is no option to expose it on a plain local network.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Turn On Remote Access") { model.setRemoteAccess(true) }.buttonStyle(.borderedProminent)
            }
            if state.busy { ProgressView().controlSize(.small) }
            if let message = state.message { Text(message).foregroundStyle(.red).font(.callout) }
        }
        .padding(20)
        .frame(width: 460)
        .disabled(state.busy)
    }
}

@MainActor
final class PairingWindowController {
    private var window: NSWindow?
    private let model: AppModel

    init(model: AppModel) { self.model = model }

    func show() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: PairingView(model: model)))
            w.title = "Pair iPhone"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}

enum QRCode {
    /// A crisp QR image for `text`, or nil if it cannot be encoded.
    static func image(for text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let out = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: out)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }
}
