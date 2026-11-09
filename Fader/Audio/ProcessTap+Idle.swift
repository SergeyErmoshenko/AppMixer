import AudioToolbox
import CoreAudio
import Foundation
import os

extension ProcessTap {
    /// Park long-idle IO *audibly*: the parked tap switches to `.unmuted`, so
    /// the process keeps its native output while the aggregate is stopped.
    /// Parking muted turned out to be a trap — the per-process IsRunningOutput
    /// flag lies for some apps (Electron helpers), so a muted-parked tap never
    /// woke and the app sat silent until restart. The unpinned failure mode is
    /// "plays at 100% uncontrolled", never "silent". One shared lightweight
    /// watcher resumes IO as soon as the process runs again.
    @MainActor
    func updatePlaybackState(isPlaying: Bool) {
        guard isPlaying != isProcessPlaying else { return }
        isProcessPlaying = isPlaying
        idleTask?.cancel()
        idleTask = nil

        if isPlaying {
            if isSuspended { resumeIO() }
            return
        }

        idleTask = Task { @MainActor [weak self] in
            do {
                // Two minutes, not thirty: pauses between tracks and call
                // silence are normal playback, not idle.
                try await Task.sleep(for: .seconds(120), tolerance: .seconds(5))
            } catch {
                return
            }
            guard let self, !isProcessPlaying else { return }
            idleTask = nil
            suspendIO()
        }
    }

    /// Safe to call away from the main actor. Core Audio property reads are
    /// synchronous IPC and can take milliseconds even though they use no CPU.
    nonisolated var hasRunningOutput: Bool {
        processObjectIDs.contains(where: { $0.readProcessIsRunningOutput() })
    }

    @MainActor
    func resumeAfterOutputStarted() {
        guard isSuspended else { return }
        isProcessPlaying = true
        resumeIO()
    }

    @MainActor
    func stopIdleLifecycle() {
        idleTask?.cancel()
        idleTask = nil
        if isSuspended { ProcessTapWakeMonitor.shared.unwatch(self) }
        isSuspended = false
    }

    @MainActor
    private func suspendIO() {
        guard !isSuspended, aggregateID.isValid, let procID else { return }
        do {
            // Park native-audible, not muted: see updatePlaybackState. The
            // parked app plays at 100% until the watcher resumes IO.
            try setTapMuteBehavior(.unmuted)
            do {
                try checked(AudioDeviceStop(aggregateID, procID), "suspend aggregate device")
            } catch {
                try? setTapMuteBehavior(.mutedWhenTapped)
                throw error
            }
            isSuspended = true
            ProcessTapWakeMonitor.shared.watch(self)
            let id = tapID
            Self.logger.debug("Suspended idle tap \(id)")
            Diag.log("tap suspended \(id) (idle ≥120 s, parked native-unmuted)")
        } catch {
            Self.logger.error("Failed to suspend idle tap: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func resumeIO() {
        guard isSuspended, aggregateID.isValid, let procID else { return }
        idleTask?.cancel()
        idleTask = nil
        do {
            try checked(AudioDeviceStart(aggregateID, procID), "resume aggregate device")
            isSuspended = false
            ProcessTapWakeMonitor.shared.unwatch(self)
            do {
                try setTapMuteBehavior(.mutedWhenTapped)
            } catch {
                // `.muted` plus a running reader still produces correct output;
                // keep audio alive and report the HAL problem for diagnostics.
                Self.logger.error("Failed to restore tap mute behavior: \(error.localizedDescription)")
            }
            let id = tapID
            Self.logger.debug("Resumed tap \(id)")
            onOutputResumed?()
        } catch {
            Self.logger.error("Failed to resume tap: \(error.localizedDescription)")
            Diag.log("tap resume FAILED \(tapID): \(error.localizedDescription) — holding silent")
            // Destroying the tap would restore native audio at full volume;
            // stay silent and let MixerEngine build a replacement.
            holdSilent()
            onBroken?()
        }
    }

    @MainActor
    func holdSilent() {
        isHeld = true
        stopIdleLifecycle()
        do {
            try setTapMuteBehavior(.muted)
        } catch {
            Self.logger.error("Failed to hold tap silent: \(error.localizedDescription)")
        }
        if aggregateID.isValid, let procID {
            AudioDeviceStop(aggregateID, procID)
        }
    }

    @MainActor
    private func setTapMuteBehavior(_ behavior: CATapMuteBehavior) throws {
        guard tapID.isValid, let tapDescription else { return }
        let previous = tapDescription.muteBehavior
        tapDescription.muteBehavior = behavior
        do {
            try tapID.writeObjectReference(kAudioTapPropertyDescription, value: tapDescription)
        } catch {
            tapDescription.muteBehavior = previous
            throw error
        }
    }
}
