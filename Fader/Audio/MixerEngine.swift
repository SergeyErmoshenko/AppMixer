import CoreAudio
import Foundation
import Observation
import os

/// The heart of AppMixer: binds the process list to per-app volume state and
/// owns one ProcessTap per adjusted app. Apps at unity gain stay untouched —
/// no tap, no processing, bit-perfect native playback.
@MainActor
@Observable
final class MixerEngine {
    private static let logger = Logger(subsystem: "com.ermoshenko.appmixer", category: "MixerEngine")

    let processMonitor = AudioProcessMonitor()
    let systemVolume = SystemVolumeController()
    let deviceMonitor = AudioDeviceMonitor()

    /// Set when tap creation fails with a permission-shaped error.
    private(set) var needsAudioCapturePermission = false

    /// False until the first successful HAL contact; the UI shows a waiting
    /// state while the audio system is unreachable.
    private(set) var isStarted = false

    private(set) var volumes: [String: AppVolume] = [:]

    /// Bundle IDs that produced audio at least once this session. Drives the
    /// Windows-mixer row lifecycle: an app stays listed after it goes silent,
    /// until it quits.
    private(set) var seenBundleIDs: Set<String> = []

    @ObservationIgnored var taps: [String: ProcessTap] = [:]
    @ObservationIgnored private let store = VolumeStore()
    @ObservationIgnored private var deviceListener: HALListener?
    @ObservationIgnored private var serviceRestartListener: HALListener?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored var rebuildPending: Set<String> = []
    @ObservationIgnored var tapFailures = 0
    @ObservationIgnored var retryTask: Task<Void, Never>?
    @ObservationIgnored private var neutralTeardownTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored var wakeResyncTask: Task<Void, Never>?
    @ObservationIgnored private var powerMonitor: AudioPowerMonitor?
    /// When each tap's process set last matched the app's live set. A tap
    /// that keeps processes the app no longer uses mutes what it holds while
    /// the app's current audio bypasses it — Kontur Talk re-registers its
    /// audio objects every ~2 s, so "wait for the set to stabilize" never
    /// fires and Talk sat silent. Instead: any mismatch older than
    /// `mismatchRebuildAfter` rebuilds the tap onto the current set. The
    /// stable signing identity made rebuilds prompt-free, so freshness now
    /// wins over quiet; short flap bursts inside the window are still
    /// absorbed.
    @ObservationIgnored private var setMismatchSince: [String: Date] = [:]
    private static let mismatchRebuildAfter: TimeInterval = 4

    func start() {
        volumes = store.load()
        processMonitor.start()
        systemVolume.start()
        deviceMonitor.start()

        installHALListeners()

        observeApps()
        observeDevices()
        powerMonitor = AudioPowerMonitor(
            onSleep: { [weak self] in self?.prepareForSleep() },
            onWake: { [weak self] in self?.recoverAfterWake() }
        )
        powerMonitor?.start()
        syncTaps()
        isStarted = true
        startTapHealthTelemetry()
    }

    /// Every 15 s, one line per live tap: is the interception delivering
    /// audio (input), is our re-render audible (output), is the aggregate
    /// alive. Distinguishes the three silence failure modes on a user's
    /// machine without a debugger attached.
    private func startTapHealthTelemetry() {
        Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(15), tolerance: .seconds(2))
                } catch {
                    break
                }
                guard let self else { break }
                // The mismatch timers only advance inside syncTaps(), which
                // normally runs on app-list changes — a quiet desktop left a
                // stale tap unnoticed for hours. This heartbeat re-evaluates
                // taps even when nothing else changed.
                self.syncTaps()
                func age(_ seconds: TimeInterval) -> String {
                    seconds.isFinite ? "\(Int(seconds.rounded()))s" : "never"
                }
                for (bundleID, tap) in self.taps {
                    Diag.log("tap health \(bundleID): input=\(age(tap.secondsSinceInputRender)) output=\(age(tap.secondsSinceAudibleRender)) suspended=\(tap.isSuspended) alive=\(tap.isAlive)")
                }
            }
        }
    }

    func volume(for app: AudioApp) -> AppVolume {
        volumes[app.bundleID] ?? AppVolume()
    }

    func setVolume(_ value: Float, for app: AudioApp) {
        var entry = volumes[app.bundleID] ?? AppVolume()
        entry.volume = max(0, min(VolumeTaper.maxPosition, value))
        apply(entry, to: app)
    }

    func toggleMute(for app: AudioApp) {
        var entry = volumes[app.bundleID] ?? AppVolume()
        entry.isMuted.toggle()
        apply(entry, to: app)
    }

    /// True when the app produced audio at least once since AppMixer launched.
    func hasPlayedThisSession(_ app: AudioApp) -> Bool {
        seenBundleIDs.contains(app.bundleID)
    }

    /// Drops the tap for an app, restoring its native audio path.
    func reset(_ app: AudioApp) {
        volumes[app.bundleID] = nil
        store.save(volumes)
        releaseTap(app.bundleID)
    }

    /// Smooths the volume jump when AppMixer exits. A tap mutes the app's
    /// native output and re-renders it attenuated, so destroying the tap
    /// restores the native output at full — an abrupt jump (and click) up from
    /// whatever level the app was held at. There is no per-app system volume
    /// to keep, so the app does return to full; ramping each tap to unity
    /// first and letting the IO proc render the ramp means the native output
    /// un-mutes at the level it is about to play, a smooth rise instead of a
    /// slam. Muted taps render silence and can't fade audibly, so they
    /// restore as-is.
    func fadeOutAndStop() {
        let fading = taps.values.filter { !$0.isMuted && $0.volume < 0.999 }
        if !fading.isEmpty {
            for tap in fading {
                tap.volume = 1.0
            }
            // ~5× the 30 ms gain ramp: long enough for the rendered level to
            // reach unity before teardown un-mutes the native output. Blocking
            // is fine here — this only runs from applicationWillTerminate, and
            // the IO proc rendering the ramp lives on its own queue.
            Thread.sleep(forTimeInterval: 0.15)
        }
        for tap in taps.values {
            tap.invalidate()
        }
        taps.removeAll()
    }

    // MARK: - Private

    func discardHALBoundState() {
        for tap in taps.values {
            tap.invalidate()
        }
        taps.removeAll()
        rebuildPending.removeAll()
    }

    func installHALListeners() {
        // Rebuild taps when the default output device changes — each aggregate
        // is pinned to a concrete device UID.
        deviceListener = AudioObjectID.system.listen(kAudioHardwarePropertyDefaultOutputDevice) {
            Task { @MainActor [weak self] in self?.reconcileTapRouting() }
        }
        serviceRestartListener = AudioObjectID.system.listen(kAudioHardwarePropertyServiceRestarted) {
            Task { @MainActor [weak self] in self?.recoverAfterAudioServiceRestart() }
        }
    }

    private func observeApps() {
        // Re-sync taps whenever the app list changes (launch/quit/playing).
        withObservationTracking {
            _ = processMonitor.apps
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.syncTaps()
                self?.observeApps()
            }
        }
    }

    private func observeDevices() {
        withObservationTracking {
            _ = deviceMonitor.devices
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.reconcileTapRouting()
                self?.observeDevices()
            }
        }
    }

    private func apply(_ entry: AppVolume, to app: AudioApp) {
        volumes[app.bundleID] = entry
        scheduleSave()

        if let tap = taps[app.bundleID] {
            tap.volume = entry.volume
            tap.isMuted = entry.isMuted
            scheduleNeutralTeardown(for: app.bundleID)
        } else if !entry.isNeutral, !app.objectIDs.isEmpty {
            // No audio processes yet (silent since launch): the stored volume
            // is picked up by syncTaps() when the app first makes sound.
            installTap(for: app, entry: entry)
        }
    }

    /// Back at 100% the tap must go: the app's audio otherwise keeps coming
    /// out of AppMixer's process, so capture that excludes the app itself
    /// (Discord screen share) picks it up. Waits for the slider to settle.
    private func scheduleNeutralTeardown(for bundleID: String) {
        neutralTeardownTasks.removeValue(forKey: bundleID)?.cancel()
        guard volumes[bundleID]?.isNeutral == true else { return }
        neutralTeardownTasks[bundleID] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self, volumes[bundleID]?.isNeutral == true else { return }
            neutralTeardownTasks[bundleID] = nil
            volumes[bundleID] = nil
            releaseTap(bundleID)
        }
    }

    /// Slider drags call apply per pixel; coalesce the UserDefaults write.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            store.save(volumes)
        }
    }

    /// Ensures every non-neutral running app has a live tap covering its
    /// current process set, and every gone app's tap is released.
    func syncTaps() {
        let apps = AudioApp.coalescedByBundleID(processMonitor.apps)
        let running = Dictionary(uniqueKeysWithValues: apps.map { ($0.bundleID, $0) })

        // Session memory for the Windows-style row lifecycle: once an app has
        // been heard, it keeps its row until it quits.
        for app in apps where app.isPlaying {
            seenBundleIDs.insert(app.bundleID)
        }

        for (bundleID, tap) in taps {
            guard let app = running[bundleID], let entry = volumes[bundleID] else {
                releaseTap(bundleID)
                continue
            }
            // A browser that spawns a new media child needs the tap rebuilt —
            // the old one keeps muting only the processes it was born with.
            // Broken taps replace immediately; a stale process set replaces
            // once the mismatch outlives mismatchRebuildAfter (flapping apps
            // never stabilize — see setMismatchSince) or the app is playing
            // right now.
            if rebuildPending.contains(bundleID) {
                Diag.log("tap rebuild \(bundleID): [\(tap.processObjectIDs.map(String.init).joined(separator: ","))] -> [\(app.objectIDs.map(String.init).joined(separator: ","))] pending=true")
                setMismatchSince[bundleID] = nil
                installTap(for: app, entry: entry)
            } else if tap.processObjectIDs != app.objectIDs {
                let since = setMismatchSince[bundleID] ?? Date()
                setMismatchSince[bundleID] = since
                let stale = Date().timeIntervalSince(since)
                if app.isPlaying || stale >= Self.mismatchRebuildAfter {
                    Diag.log("tap rebuild \(bundleID): mismatch \(String(format: "%.1f", stale))s playing=\(app.isPlaying) [\(tap.processObjectIDs.map(String.init).joined(separator: ","))] -> [\(app.objectIDs.map(String.init).joined(separator: ","))]")
                    setMismatchSince[bundleID] = nil
                    installTap(for: app, entry: entry)
                }
            } else {
                setMismatchSince[bundleID] = nil
                tap.updatePlaybackState(isPlaying: app.isPlaying, audibleAgo: tap.secondsSinceAudibleRender)
            }
        }
        for (bundleID, entry) in volumes where !entry.isNeutral {
            // objectIDs empty = the app runs but has no Core Audio processes
            // yet; its saved volume applies when sound first appears.
            guard taps[bundleID] == nil, let app = running[bundleID], !app.objectIDs.isEmpty else { continue }
            installTap(for: app, entry: entry)
        }
    }

    /// Make-before-break: the replacement starts before the old tap goes, so
    /// the app is never left on its native output at full volume in between.
    private func installTap(for app: AudioApp, entry: AppVolume) {
        let bundleID = app.bundleID
        let old = taps[bundleID]
        do {
            let tap = try makeTap(for: app, entry: entry, replacing: old)
            taps[bundleID] = tap
            Diag.log("tap ok \(bundleID) procs=\(app.objectIDs.count) vol=\(entry.volume) muted=\(entry.isMuted) held=\(tap.isHeld)")
            if tap.isHeld {
                rebuildPending.insert(bundleID)
                scheduleTapRetry()
            } else {
                rebuildPending.remove(bundleID)
                tapFailures = 0
                needsAudioCapturePermission = false
            }
            if let old { retire(old) }
        } catch {
            Self.logger.error("Tap failed for \(bundleID): \(error.localizedDescription)")
            Diag.log("tap FAIL \(bundleID): \(error.localizedDescription)")
            if let halError = error as? HALError, halError.isPermissionDenied {
                Diag.log("tap permission-denied \(bundleID) — enable System Audio Recording for AppMixer")
                needsAudioCapturePermission = true
                if old == nil { return }
            }
            scheduleTapRetry()
            // A tap that still renders keeps attenuating the processes it has;
            // only one that can't play anymore needs holding silent.
            guard let old else { return }
            switch TapRebuildPolicy.brokenTap(isAlive: old.isAlive, isHeld: old.isHeld) {
            case .hold:
                rebuildPending.insert(bundleID)
                old.holdSilent()
            case .keepPlaying:
                break
            }
        }
    }

    /// Rebuilds only the taps that no longer play where they should, so
    /// unrelated apps don't blip. Stale = resolved targets changed (object IDs
    /// too — devices re-publish under an old UID), aggregate died, or resolve
    /// failed; a wedged tap keeps its app muted until its replacement runs.
    func reconcileTapRouting() {
        for (bundleID, tap) in taps {
            guard let entry = volumes[bundleID] else { continue }
            let desired = (try? resolvedOutputs(for: entry)) ?? []
            if desired == tap.activatedOutputs, tap.isAlive, !desired.isEmpty { continue }
            Diag.log("tap stale \(bundleID): alive=\(tap.isAlive) desired=\(desired.map { "\($0.uid)#\($0.id)" }) activated=\(tap.activatedOutputs.map { "\($0.uid)#\($0.id)" })")
            rebuildPending.insert(bundleID)
        }
        syncTaps()
    }
}
