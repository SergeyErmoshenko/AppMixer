import CoreAudio
import Foundation

extension MixerEngine {
    func makeTap(for app: AudioApp, entry: AppVolume, replacing old: ProcessTap?) throws -> ProcessTap {
        let outputs = try resolvedOutputs(for: entry)
        let tap = ProcessTap(
            processObjectIDs: app.objectIDs,
            volume: entry.volume,
            isMuted: entry.isMuted
        )
        if old != nil { tap.rampInFromSilence() }
        do {
            try tap.activate(outputs: outputs)
        } catch {
            guard old == nil, tap.tapID.isValid else { throw error }
            ProcessTap.logger.error("Tap activation failed; holding output silent: \(error.localizedDescription)")
            Diag.log("tap activate-failed \(app.bundleID), holding silent: \(error.localizedDescription)")
            tap.holdSilent()
        }
        if tap.isHeld, old != nil {
            throw HALError.operation(kAudioDeviceUnsupportedFormatError, "verify aggregate stream format")
        }
        let bundleID = app.bundleID
        tap.onOutputResumed = { [weak self] in self?.processMonitor.refresh() }
        tap.onBroken = { [weak self] in self?.rebuildBrokenTap(bundleID) }
        tap.updatePlaybackState(isPlaying: app.isPlaying)
        return tap
    }

    /// Fades the replaced tap out under the new one's fade-in, then tears it
    /// down; the processes stay muted throughout because the new tap reads them.
    func retire(_ tap: ProcessTap) {
        tap.volume = 0
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            tap.invalidate()
        }
    }

    /// Releasing restores the app's native output at full volume.
    func releaseTap(_ bundleID: String) {
        taps.removeValue(forKey: bundleID)?.invalidate()
        rebuildPending.remove(bundleID)
    }

    func rebuildBrokenTap(_ bundleID: String) {
        Diag.log("tap onBroken \(bundleID) — resume failed, replacing")
        rebuildPending.insert(bundleID)
        syncTaps()
    }

    /// No HAL event is guaranteed to follow a failure — a steadily playing app
    /// never changes the process list — so retry on a timer instead.
    func scheduleTapRetry() {
        guard retryTask == nil else { return }
        tapFailures += 1
        let delay = TapRebuildPolicy.retryDelay(afterFailures: tapFailures)
        retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            retryTask = nil
            syncTaps()
        }
    }

    /// The device an app's tap should play through: the system default.
    func resolvedOutputs(for entry: AppVolume) throws -> [ProcessTap.Output] {
        let id = try AudioObjectID.readDefaultOutputDevice()
        return try [ProcessTap.Output(uid: id.readDeviceUID(), id: id)]
    }
}
