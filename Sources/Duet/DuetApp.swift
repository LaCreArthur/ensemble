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
                Toggle("Duet", isOn: $duet.isOn).toggleStyle(.switch).labelsHidden()
            }
            Text(duet.status).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            Divider()
            volumeRow("Main volume", value: $duet.mainVolume)

            Text("This Mac").font(.subheadline.bold())
            ForEach(duet.outputs) { output in
                Toggle(output.name, isOn: Binding(
                    get: { duet.chosenOutputs.contains(output.uid) },
                    set: { duet.chosenOutputs.formSymmetricDifference([output.uid]); _ = $0 }))
                volumeRow(nil, value: volume(output.uid))
            }

            Text("Other Mac").font(.subheadline.bold())
            Picker("Other Mac", selection: $duet.otherMacID) {
                Text("None").tag(String?.none)
                ForEach(duet.receivers) { Text($0.name).tag(Optional($0.id)) }
                if let id = duet.otherMacID, !duet.receivers.contains(where: { $0.id == id }) {
                    Text(duet.rememberedOtherMacName ?? "Previous choice").tag(Optional(id))
                }
            }
            .labelsHidden()
            if duet.otherMacID != nil {
                volumeRow(nil, value: volume(Duet.other))
                if !duet.otherMacStatus.isEmpty {
                    Text(duet.otherMacStatus).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()
            Button(duet.isTuning ? "Tuning…" : "Tune sync with the microphone") { duet.tuneSync() }
                .disabled(!duet.isOn || duet.isTuning)
            Button("Copy remote link for the other Mac") { duet.copyRemoteLink() }
                .help("Paste it in Safari on the other Mac: play/pause, tracks and volumes from there.")
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
