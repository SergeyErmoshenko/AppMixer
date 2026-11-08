import os

private let audioServiceLogger = Logger(subsystem: "com.ermoshenko.appmixer", category: "MixerEngine")

extension MixerEngine {
    /// A Core Audio service reset invalidates cached object IDs and every
    /// listener registered by the client. Recreate all HAL-bound state instead
    /// of letting stale taps, sliders, and device lists limp on indefinitely.
    func recoverAfterAudioServiceRestart() {
        audioServiceLogger.warning("Core Audio service restarted; rebuilding HAL state")
        prepareForSleep()
        discardHALBoundState()

        processMonitor.recoverAfterServiceRestart()
        deviceMonitor.recoverAfterServiceRestart()
        systemVolume.recoverAfterServiceRestart()
        installHALListeners()
        syncTaps()

        // The reset notification can precede the final device publication.
        // Reuse the bounded wake resync for one tolerant second pass.
        recoverAfterWake()
    }
}
