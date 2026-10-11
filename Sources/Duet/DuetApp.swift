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
        .defaultLaunchBehavior(duet.link.pairing == nil ? .presented : .suppressed)
    }
}

/// The first-use guide, shown at launch until this Mac is paired: each step turns green once done.
struct WelcomeView: View {
    @Bindable var duet: Duet
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        let guide = duet.guide
        let current = !guide.found && !guide.paired ? 1 : !guide.paired ? 2 : !guide.playing ? 3 : 4
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: "hifispeaker.2.fill").font(.system(size: 34)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Welcome to Ensemble").font(.title2.bold())
                    Text("Hear this Mac's sound on your other Mac too, in sync.").foregroundStyle(.secondary)
                }
            }
            step(1, current, "Open Ensemble on your other Mac") {
                if guide.denied {
                    Text("macOS does not let Ensemble look for your other Mac. Allow it in Local Network settings.")
                    Button("Open Local Network Settings") { Duet.openLocalNetworkSettings() }
                } else {
                    Text("Install it there too. When macOS asks, allow Ensemble to find devices on your network.")
                }
            }
            step(2, current, "Pair the two Macs") {
                ForEach(duet.link.pairable, id: \.id) { peer in
                    Button("Pair with \(peer.name)…") { duet.pair(with: peer) }
                }
                Text("Both Macs then show a code. Click Pair on each Mac if the codes are the same.")
                if let note = duet.link.note { Text(note).foregroundStyle(.secondary) }
            }
            step(3, current, "Play a sound on both Macs") {
                Text("On the Mac whose sound you want on both, turn on sharing and play some music. When macOS asks, allow Ensemble to record the sound.")
                Toggle("Share this Mac's sound", isOn: $duet.isOn).toggleStyle(.switch)
            }
            Divider()
            HStack(spacing: 6) {
                Text(current > 3 ? "Ensemble works. It lives in the menu bar:" : "Ensemble lives in the menu bar:")
                Image(systemName: "hifispeaker.2")
                Spacer()
                Button("Done") { dismissWindow(id: "welcome") }.keyboardShortcut(.defaultAction)
            }
            .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 440)
        .onAppear { NSApp.activate() }
    }

    private func step(_ number: Int, _ current: Int, _ title: String, @ViewBuilder detail: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: number < current ? "checkmark.circle.fill" : "\(number).circle")
                .font(.title2)
                .foregroundStyle(number < current ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                if number == current {
                    detail().font(.callout).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .opacity(number > current ? 0.45 : 1)
    }
}

struct DuetMenu: View {
    @Bindable var duet: Duet

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Ensemble").font(.headline)
                Spacer()
                Toggle("Share this Mac's sound", isOn: $duet.isOn).toggleStyle(.switch).labelsHidden()
                    .help("On: this Mac's sound plays here and on the other Mac.")
            }
            Text(duet.status).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
