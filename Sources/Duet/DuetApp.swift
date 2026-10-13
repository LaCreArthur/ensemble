import DuetCore
import SwiftUI

@main
struct DuetApp: App {
    @State private var duet = Duet()

    var body: some Scene {
        MenuBarExtra {
            DuetMenu(duet: duet)
        } label: {
            Image(systemName: duet.isPlaying ? "hifispeaker.2.fill" : "hifispeaker.2")
        }
        .menuBarExtraStyle(.window)

        Window("Ensemble", id: "welcome") {
            WelcomeView(duet: duet)
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
    @Bindable var duet: Duet
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        let guide = duet.guide
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Welcome to Ensemble").font(.title2.bold())
                    Text("Play your Mac's sound on all your speakers, and on your other Mac, in sync.").foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            step(1, done: guide.device, "Keep video in sync") {
                Text("Ensemble adds a sound device to this Mac, so video players hold the picture back to match the sound. macOS asks for your password, and the sound stops for a second.")
                Button("Install Sound Device…") { duet.installDevice() }
            }
            step(2, done: guide.playing, "Play on all your speakers") {
                Text("Turn on sharing, then tick your speakers in Ensemble's menu: this Mac's own, Bluetooth speakers, displays. When macOS asks, allow Ensemble to record this Mac's sound: this is how it plays your apps on every speaker.")
                Toggle("Share this Mac's sound", isOn: $duet.isOn).toggleStyle(.switch)
            }
            step(3, done: guide.paired, "Add your other Mac (optional)") {
                if guide.denied {
                    Text("macOS does not let Ensemble look for your other Mac. Allow it in Local Network settings.")
                    Button("Open Local Network Settings") { Duet.openLocalNetworkSettings() }
                } else if duet.link.pairable.isEmpty {
                    Text("Install Ensemble there too and open it. When macOS asks, allow Ensemble to find devices on your local network: this is how your Macs find each other.")
                } else {
                    ForEach(duet.link.pairable, id: \.id) { peer in
                        Button("Pair with \(peer.name)…") { duet.pair(with: peer) }
                    }
                    Text("Both Macs then show a code. Click Pair on each Mac if the codes are the same. The sound goes only to the Mac you pair.")
                }
                if let note = duet.link.note { Text(note).foregroundStyle(.secondary) }
            }
            Divider()
            HStack(spacing: 6) {
                Text("Ensemble lives in the menu bar:")
                Image(systemName: "hifispeaker.2")
                Spacer()
                Link("Source code", destination: URL(string: "https://github.com/LaCreArthur/duet")!).foregroundStyle(.tint)
                Button("Done") { dismissWindow(id: "welcome") }.keyboardShortcut(.defaultAction).padding(.leading, 8)
            }
            .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 440)
        .onAppear { NSApp.activate() }
        .onDisappear { UserDefaults.standard.set(true, forKey: "welcomed") }
    }

    private func step(_ number: Int, done: Bool, _ title: String, @ViewBuilder detail: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "\(number).circle")
                .font(.title2)
                .foregroundStyle(done ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                if !done {
                    detail().font(.callout).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

struct DuetMenu: View {
    @Bindable var duet: Duet
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Ensemble").font(.headline)
                Spacer()
                Toggle("Share this Mac's sound", isOn: $duet.isOn).toggleStyle(.switch).labelsHidden()
                    .help("On: this Mac's sound plays here and on the other Mac.")
            }
            Text(duet.status).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if duet.isOn && !duet.guide.device {
                Text("Video runs ahead of the sound until you install Ensemble's sound device.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Install Sound Device…") { duet.installDevice() }
            }
            if duet.isReceiving {
                HStack(spacing: 22) {
                    Button { duet.control(.previous) } label: { Image(systemName: "backward.fill") }
                    Button { duet.control(.playPause) } label: { Image(systemName: "playpause.fill") }
                    Button { duet.control(.next) } label: { Image(systemName: "forward.fill") }
                }
                .buttonStyle(.borderless)
                .font(.title3)
                .frame(maxWidth: .infinity)
            }

            Divider()
            volumeRow("Volume", value: $duet.mainVolume)

            Text("This Mac").font(.subheadline.bold())
            ForEach(duet.outputs) { output in
                Toggle(output.name, isOn: Binding(
                    get: { duet.chosenOutputs.contains(output.uid) },
                    set: { duet.chosenOutputs.formSymmetricDifference([output.uid]); _ = $0 }))
                volumeRow(nil, value: volume(output.uid))
            }

            Text("Other Mac").font(.subheadline.bold())
            if !duet.otherMacStatus.isEmpty {
                Text(duet.otherMacStatus).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(duet.link.pairable, id: \.id) { peer in
                Button("Pair with \(peer.name)…") { duet.pair(with: peer) }
            }
            if duet.guide.denied {
                Button("Open Local Network Settings") { Duet.openLocalNetworkSettings() }
            }

            Divider()
            Button(duet.isTuning ? "Tuning…" : "Tune sync with the microphone") { duet.tuneSync() }
                .disabled(!duet.isPlaying || duet.isTuning)
            if let release = duet.newRelease {
                Button("Get Ensemble \(release.version)…") { NSWorkspace.shared.open(release.page) }
            }
            Button("Setup Guide…") { NSApp.activate(); openWindow(id: "welcome") }
            Toggle("Open at login", isOn: Binding(get: { duet.openAtLogin }, set: { duet.openAtLogin = $0 }))
            Button("Quit Ensemble") { NSApplication.shared.terminate(nil) }
        }
        .padding(14)
        .frame(width: 300)
    }

    private func volume(_ key: String) -> Binding<Double> {
        Binding(get: { duet.volume(key) }, set: { duet.setVolume(key, $0) })
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

