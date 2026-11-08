import CoreAudio
import Observation
import os

/// Watches the output devices and the system default. AppMixer never switches
/// the default itself — it only needs to notice changes so per-app taps can be
/// rebuilt onto the new device.
@MainActor
@Observable
final class AudioDeviceMonitor {
    private static let logger = Logger(subsystem: "com.ermoshenko.appmixer", category: "AudioDeviceMonitor")

    let direction: AudioDirection

    private(set) var devices: [AudioDevice] = []
    private(set) var defaultDeviceID = AudioDeviceID.unknown

    @ObservationIgnored private var listeners: [HALListener] = []
    /// HAL emits device/default changes in bursts (one per aggregate member and
    /// property). Collapse one main-queue burst into one enumeration instead of
    /// queueing a full synchronous refresh for every callback.
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    init(direction: AudioDirection = .output) {
        self.direction = direction
    }

    func start() {
        installListeners()
        refresh()
    }

    /// A service reset can preserve UIDs while replacing every AudioObjectID.
    /// Empty the stale snapshot and re-listen before a fresh enumeration.
    func recoverAfterServiceRestart() {
        refreshTask?.cancel()
        refreshTask = nil
        listeners.removeAll()
        devices = []
        defaultDeviceID = .unknown
        installListeners()
        refresh()
    }

    private func installListeners() {
        listeners = [
            AudioObjectID.system.listen(kAudioHardwarePropertyDevices) {
                Task { @MainActor [weak self] in self?.scheduleRefresh() }
            },
            AudioObjectID.system.listen(direction.defaultDeviceSelector) {
                Task { @MainActor [weak self] in self?.scheduleRefresh() }
            },
        ]
    }

    func refresh() {
        // An explicit refresh (startup/wake) supersedes a queued burst refresh
        // that has not started yet.
        refreshTask?.cancel()
        refreshTask = nil

        defaultDeviceID = (try? AudioObjectID.readDefaultDevice(direction)) ?? .unknown

        guard let ids = try? AudioObjectID.system.readArray(kAudioHardwarePropertyDevices, of: AudioDeviceID.self)
        else {
            Self.logger.error("Failed to read device list")
            return
        }

        devices = ids.compactMap { id in
            guard id.channelCount(scope: direction.scope) > 0,
                  let device = AudioDevice(id: id),
                  !device.isFaderPlumbing
            else { return nil }
            return device
        }
    }

    deinit {
        refreshTask?.cancel()
    }

    private func scheduleRefresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(50), tolerance: .milliseconds(25))
            } catch {
                return
            }
            guard let self else { return }
            refreshTask = nil
            refresh()
        }
    }
}

extension AudioObjectID {
    /// Total channels across all streams of the given scope.
    func channelCount(scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let listPtr = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { listPtr.deallocate() }
        guard AudioObjectGetPropertyData(self, &address, 0, nil, &size, listPtr) == noErr else { return 0 }
        let buffers = UnsafeMutableAudioBufferListPointer(listPtr.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
