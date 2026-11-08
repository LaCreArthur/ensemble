import EnsembleCore
import SwiftUI

@main
struct EnsembleApp: App {
    @State private var ensemble = Ensemble()

    var body: some Scene {
        MenuBarExtra {
            EnsembleMenu(ensemble: ensemble)
        } label: {
            Image(systemName: ensemble.isPlaying ? "hifispeaker.2.fill" : "hifispeaker.2")
        }
        .menuBarExtraStyle(.window)

        Window("Ensemble", id: "welcome") {
            WelcomeView(ensemble: ensemble)
        }
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(UserDefaults.standard.bool(forKey: "welcomed") ? .suppressed : .presented)
    }
}

/// The setup guide, shown at first launch and from the menu: each step turns green once done, and says
/// why macOS asks what it asks just before it does. The other Mac is optional: one Mac can play on all
/// its speakers.
struct WelcomeView: View {
    @Bindable var ensemble: Ensemble
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var window: NSWindow?

    var body: some View {
        let guide = ensemble.guide
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Welcome to Ensemble").font(.title2.bold())
                    Text("Play your Mac's sound on all your speakers, and on your other Mac, in sync.").foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            step(1, done: guide.device, "Add Ensemble's sound device") {
                Text("Your apps play to Ensemble's sound device while you share, and video players hold the picture back to match the sound. macOS asks for your password, and the sound stops for a second.")
                InstallDeviceButton(ensemble: ensemble)
            }
            step(2, done: guide.sharing, keepDetail: true, "Play on all your speakers") {
                if !guide.device {
                    Text("Add the sound device first.")
                } else if !guide.sharing {
                    Text("Turn on sharing.")
                    Toggle("Share this Mac's sound", isOn: $ensemble.isOn).toggleStyle(.switch)
                } else {
                    Text("Tick the speakers to play on. You can change them later in the menu bar.")
                    ForEach(ensemble.outputs) { output in
                        Toggle(output.name, isOn: ensemble.chosen(output.uid))
                    }
                }
            }
            step(3, done: guide.paired, "Add your other Mac (optional)") {
                if guide.denied {
                    Text("macOS does not let Ensemble look for your other Mac. Allow it in Local Network settings.")
                    LocalNetworkSettingsButton()
                } else if !guide.looking {
                    Text("Install Ensemble on your other Mac too, and click Find on both Macs. When macOS asks, allow Ensemble to find devices on your local network: this is how your Macs find each other.")
                    FindOtherMacButton(ensemble: ensemble)
                } else if ensemble.link.pairable.isEmpty {
                    Text("Looking for your other Mac. Open Ensemble there and click Find My Other Mac.")
                } else {
                    PairButtons(ensemble: ensemble)
                    Text("Both Macs then show a code. Click Pair on each Mac if the codes are the same. The sound goes only to the Mac you pair.")
                }
                if let note = ensemble.link.note { Text(note).foregroundStyle(.secondary) }
            }
            Divider()
            HStack(spacing: 6) {
                Text("Ensemble lives in the menu bar:")
                Image(systemName: "hifispeaker.2")
                Spacer()
                Link("Source code", destination: URL(string: "https://github.com/LaCreArthur/ensemble")!).foregroundStyle(.tint)
                Button("Done") { dismissWindow(id: "welcome") }.keyboardShortcut(.defaultAction).padding(.leading, 8)
            }
            .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 440)
        .onAppear { NSApp.activate() }
        // macOS's own prompts (password, local network) take the focus, and when they close macOS gives it to
        // the last app with a Dock icon and refuses a menu bar app's request for it: put the guide back on
        // top after each step without the focus.
        .background(WindowReader { window = $0 })
        .onChange(of: guide) { window?.orderFrontRegardless() }
        .onDisappear { UserDefaults.standard.set(true, forKey: "welcomed") }
    }

    private func step(_ number: Int, done: Bool, keepDetail: Bool = false, _ title: String,
                      @ViewBuilder detail: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "\(number).circle")
                .font(.title2)
                .foregroundStyle(done ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                if !done || keepDetail {
                    detail().font(.callout).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

struct EnsembleMenu: View {
    @Bindable var ensemble: Ensemble
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Ensemble").font(.headline)
                Spacer()
                Toggle("Share this Mac's sound", isOn: $ensemble.isOn).toggleStyle(.switch).labelsHidden()
                    .help("On: this Mac's sound plays here and on the other Mac.")
            }
            Text(ensemble.status).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if ensemble.isOn && !ensemble.guide.device {
                Text("Ensemble shares this Mac's sound through its own sound device.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                InstallDeviceButton(ensemble: ensemble)
            }
            if ensemble.isReceiving {
                HStack(spacing: 22) {
                    Button { ensemble.control(.previous) } label: { Image(systemName: "backward.fill") }
                    Button { ensemble.control(.playPause) } label: { Image(systemName: "playpause.fill") }
                    Button { ensemble.control(.next) } label: { Image(systemName: "forward.fill") }
                }
                .buttonStyle(.borderless)
                .font(.title3)
                .frame(maxWidth: .infinity)
            }

            Divider()
            volumeRow("Volume", value: $ensemble.mainVolume)

            Text("This Mac").font(.subheadline.bold())
            ForEach(ensemble.outputs) { output in
                Toggle(output.name, isOn: ensemble.chosen(output.uid))
                volumeRow(nil, value: volume(output.uid))
            }

            Text("Other Mac").font(.subheadline.bold())
            if !ensemble.otherMacStatus.isEmpty {
                Text(ensemble.otherMacStatus).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            PairButtons(ensemble: ensemble)
            if ensemble.guide.denied {
                LocalNetworkSettingsButton()
            } else if !ensemble.guide.looking {
                FindOtherMacButton(ensemble: ensemble)
            }

            Divider()
            Button(ensemble.isTuning ? "Tuning…" : "Tune sync with the microphone") { ensemble.tuneSync() }
                .disabled(!ensemble.isPlaying || ensemble.isTuning)
            if let release = ensemble.newRelease {
                Button("Get Ensemble \(release.version)…") { NSWorkspace.shared.open(release.page) }
            }
            Button("Setup Guide…") { NSApp.activate(); openWindow(id: "welcome") }
            Toggle("Open at login", isOn: Binding(get: { ensemble.openAtLogin }, set: { ensemble.openAtLogin = $0 }))
            Button("Quit Ensemble") { NSApplication.shared.terminate(nil) }
        }
        .padding(14)
        .frame(width: 300)
    }

    private func volume(_ key: String) -> Binding<Double> {
        Binding(get: { ensemble.volume(key) }, set: { ensemble.setVolume(key, $0) })
    }

    private func volumeRow(_ title: String?, value: Binding<Double>) -> some View {
        HStack {
            Image(systemName: "speaker.fill").foregroundStyle(.secondary)
            Slider(value: value, in: 0...1) { if let title { Text(title) } }
            Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
        }
        .labelsHidden()
    }
}

extension Ensemble {
    /// Whether output `uid` is ticked, as a switch.
    func chosen(_ uid: String) -> Binding<Bool> {
        Binding(get: { self.chosenOutputs.contains(uid) },
                set: { if $0 { self.chosenOutputs.insert(uid) } else { self.chosenOutputs.remove(uid) } })
    }
}

/// One button per Mac running Ensemble nearby that can be paired.
private struct PairButtons: View {
    let ensemble: Ensemble

    var body: some View {
        ForEach(ensemble.link.pairable, id: \.id) { peer in
            Button("Pair with \(peer.name)…") { ensemble.pair(with: peer) }
        }
    }
}

private struct FindOtherMacButton: View {
    let ensemble: Ensemble
    var body: some View { Button("Find My Other Mac") { ensemble.findOtherMac() } }
}

private struct InstallDeviceButton: View {
    let ensemble: Ensemble
    var body: some View { Button("Install Sound Device…") { ensemble.installDevice() } }
}

private struct LocalNetworkSettingsButton: View {
    var body: some View { Button("Open Local Network Settings") { Ensemble.openLocalNetworkSettings() } }
}

/// Gives the window its view is in, once it is in one.
private struct WindowReader: NSViewRepresentable {
    let found: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { if let window = view.window { found(window) } }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}
