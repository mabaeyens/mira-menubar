import AppKit
import SwiftUI
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
