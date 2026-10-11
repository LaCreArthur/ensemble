import CoreAudio
import Foundation

/// Tells whether any app plays sound (runs audio output), apart from the excluded processes, from the
/// system's list of audio processes. Needs no permission. Changes arrive on the main queue.
public final class PlaybackMonitor {
    public private(set) var isPlaying = false
    public var onChange: ((Bool) -> Void)?

    private let excluded: Set<pid_t>
    private var tokens: [CA.ListenerToken] = []
    private var watched: [AudioObjectID: CA.ListenerToken] = [:]

    public init(excluding pids: [pid_t]) { excluded = Set(pids) }

    public func start() {
        tokens = [kAudioHardwarePropertyProcessObjectList, kAudioHardwarePropertyDevices].map {
            CA.listen(CA.system, $0, queue: .main) { [weak self] in self?.refresh() }
        }
        refresh()
    }

    private func refresh() {
        let processes = (try? CA.array(CA.system, kAudioHardwarePropertyProcessObjectList, as: AudioObjectID.self)) ?? []
        // The system announces a process starting or stopping all its audio, and a device starting or
        // stopping for anyone (an app that records and then also plays shows only there).
        let triggers = processes.map { ($0, kAudioProcessPropertyIsRunning) }
            + OutputDevice.all().map { ($0.id, kAudioDevicePropertyDeviceIsRunningSomewhere) }
        watched = Dictionary(uniqueKeysWithValues: triggers.map { id, selector in
            (id, watched[id] ?? CA.listen(id, selector, queue: .main) { [weak self] in self?.refresh() })
        })
        let playing = processes.contains { id in
            guard let pid = try? CA.scalar(id, kAudioProcessPropertyPID, as: pid_t.self), !excluded.contains(pid) else { return false }
            return (try? CA.scalar(id, kAudioProcessPropertyIsRunningOutput, as: UInt32.self)) == 1
        }
        if playing != isPlaying {
            isPlaying = playing
            onChange?(playing)
        }
    }
}
