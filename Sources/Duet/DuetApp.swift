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
    }
}

struct DuetMenu: View {
    @Bindable var duet: Duet

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Duet").font(.headline)
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
            volumeRow("Main volume", value: $duet.shownMainVolume)

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

            Divider()
            Button(duet.isTuning ? "Tuning…" : "Tune sync with the microphone") { duet.tuneSync() }
                .disabled(!duet.isPlaying || duet.isTuning)
            Toggle("Open at login", isOn: Binding(get: { duet.openAtLogin }, set: { duet.openAtLogin = $0 }))
            Button("Quit Duet") { NSApplication.shared.terminate(nil) }
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
