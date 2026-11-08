import AudioToolbox
import CoreAudio
import Observation
import os

/// Reads and writes the default device's main volume and mute for one
/// direction, staying in sync with changes made elsewhere (volume keys,
/// Control Center). Input gain is absent or read-only on plenty of devices
/// (pro interfaces put it on a hardware knob) — `canSetVolume`/`canMute`
/// tell the UI when to disable the controls.
@MainActor
@Observable
final class SystemVolumeController {
    private static let logger = Logger(subsystem: "dev.pantafive.fader", category: "SystemVolume")

    let direction: AudioDirection

    private(set) var volume: Float = 1.0
    private(set) var isMuted = false
    private(set) var deviceName = ""
    private(set) var canSetVolume = true
    private(set) var canMute = true

    @ObservationIgnored private var endpoint: VolumeEndpoint
    @ObservationIgnored private var defaultDeviceListener: HALListener?
    @ObservationIgnored private var deviceListeners: [HALListener] = []

    init(direction: AudioDirection = .output) {
        self.direction = direction
        endpoint = VolumeEndpoint(deviceID: .unknown, scope: direction.scope)
    }

    func start() {
        installDefaultDeviceListener()
        attachToDefaultDevice()
    }

    /// Replaces both the system and device listeners after Core Audio reset;
    /// their registrations and the endpoint object ID are no longer valid.
    func recoverAfterServiceRestart() {
        defaultDeviceListener = nil
        deviceListeners.removeAll()
        endpoint.deviceID = .unknown
        installDefaultDeviceListener()
        attachToDefaultDevice()
    }

    private func installDefaultDeviceListener() {
        defaultDeviceListener = AudioObjectID.system.listen(direction.defaultDeviceSelector) {
            Task { @MainActor [weak self] in self?.attachToDefaultDevice() }
        }
    }

    func setVolume(_ value: Float) {
        if let applied = endpoint.writeVolume(value) {
            volume = applied
        } else {
            readBack() // keep published state honest when the HAL write fails
        }
    }

    func toggleMute() {
        if let muted = endpoint.writeMute(!isMuted) {
            isMuted = muted
        } else {
            readBack()
        }
    }

    /// Rebinds listeners after sleep/wake even if HAL omitted the expected
    /// default-device notification.
    func resync() {
        attachToDefaultDevice()
    }

    // MARK: - Private

    private func attachToDefaultDevice() {
        guard let next = try? AudioObjectID.readDefaultDevice(direction), next.isValid else { return }
        endpoint.deviceID = next
        deviceName = (try? next.readString(kAudioObjectPropertyName)) ?? ""
        canSetVolume = next.isSettable(kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                       scope: direction.scope)
        canMute = next.isSettable(kAudioDevicePropertyMute, scope: direction.scope)

        deviceListeners = [
            next.listen(kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                        scope: direction.scope) {
                Task { @MainActor [weak self] in self?.readBack() }
            },
            next.listen(kAudioDevicePropertyMute, scope: direction.scope) {
                Task { @MainActor [weak self] in self?.readBack() }
            },
        ]
        readBack()
    }

    private func readBack() {
        if let value = endpoint.readVolume() {
            volume = value
        }
        if let muted = endpoint.readMute() {
            isMuted = muted
        }
    }
}

/// The default device's VirtualMainVolume and mute in one scope — the HAL
/// read/write bodies behind the master volume slider. Lifecycle (listeners,
/// capability probes, device attachment) stays with the owner above.
@MainActor
struct VolumeEndpoint {
    var deviceID: AudioObjectID
    let scope: AudioObjectPropertyScope

    /// Clamps and writes; returns the value to publish, nil when the HAL
    /// write failed and the owner should re-read instead.
    func writeVolume(_ value: Float) -> Float? {
        let clamped = max(0, min(1, value))
        do {
            try deviceID.write(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: scope, value: clamped)
            return clamped
        } catch {
            return nil
        }
    }

    /// Writes the mute flag; returns the state to publish, nil on failure.
    func writeMute(_ muted: Bool) -> Bool? {
        do {
            try deviceID.write(kAudioDevicePropertyMute, scope: scope, value: UInt32(muted ? 1 : 0))
            return muted
        } catch {
            return nil
        }
    }

    func readVolume() -> Float? {
        var value: Float32 = 1.0
        guard (try? deviceID.read(kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                  scope: scope,
                                  into: &value)) != nil else { return nil }
        return value
    }

    func readMute() -> Bool? {
        var muted: UInt32 = 0
        guard (try? deviceID.read(kAudioDevicePropertyMute, scope: scope, into: &muted)) != nil else { return nil }
        return muted != 0
    }
}
