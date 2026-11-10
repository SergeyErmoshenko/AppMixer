import AppKit
import CoreAudio
import Observation
import os

/// Publishes every running regular application, merging two sources:
/// the HAL's audio process list (apps that Core Audio knows about — they
/// made sound) and NSWorkspace (all GUI apps). Helper processes (browser
/// media children, Electron renderers) group under their responsible
/// application. Apps that never made sound keep a row too, so a volume can
/// be set ahead of time and applies from the app's first sound.
@MainActor
@Observable
final class AudioProcessMonitor {
    private static let logger = Logger(subsystem: "com.ermoshenko.appmixer", category: "AudioProcessMonitor")

    private(set) var apps: [AudioApp] = []

    @ObservationIgnored private var listListener: HALListener?
    @ObservationIgnored private var pendingRefresh: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    /// Written only on the main actor; deinit reads it nonisolated, hence
    /// `nonisolated(unsafe)` — the same escape hatch ProcessTap uses.
    @ObservationIgnored nonisolated(unsafe) private var workspaceObservers: [NSObjectProtocol] = []
    /// Last logged orphan set — dedupes the X-ray line between refreshes.
    @ObservationIgnored private var lastPlayingOrphans: [String] = []

    func start() {
        guard pollTask == nil else { return } // idempotent: a second call must not double-listen
        installListListener()
        installWorkspaceObservers()
        // Per-process IsRunningOutput flips do NOT arrive in practice
        // (observed on macOS 26), so the playing state is polled. Reading the
        // flags of a few dozen process objects costs microseconds.
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                // Generous tolerance lets the kernel coalesce the wakeup with
                // other timers — playing-state freshness doesn't need precision.
                do {
                    try await Task.sleep(for: .seconds(2), tolerance: .milliseconds(500))
                } catch {
                    break
                }
                guard let self else { break }
                refresh()
            }
        }
        refresh()
    }

    /// Core Audio resets discard client listeners and invalidate process
    /// object IDs. Keep the inexpensive poll task, but replace the listener
    /// and published objects before attempting a fresh enumeration.
    func recoverAfterServiceRestart() {
        pendingRefresh?.cancel()
        pendingRefresh = nil
        apps = []
        installListListener()
        refresh()
    }

    deinit {
        pollTask?.cancel()
        pendingRefresh?.cancel()
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    private func installListListener() {
        // List changes (process appeared / exited) arrive as HAL notifications.
        listListener = AudioObjectID.system.listen(kAudioHardwarePropertyProcessObjectList) {
            Task { @MainActor [weak self] in self?.scheduleRefresh() }
        }
    }

    /// Plain app launch/quit never touches the HAL list, so the workspace
    /// notifications drive those rows — a launched app becomes adjustable at
    /// once instead of waiting for the next poll tick.
    private func installWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in
                Task { @MainActor [weak self] in self?.scheduleRefresh() }
            })
        }
    }

    /// Coalesces listener bursts: HAL fires once per process and once per
    /// output-state flip, often a dozen times within a few milliseconds.
    private func scheduleRefresh() {
        pendingRefresh?.cancel()
        pendingRefresh = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    func refresh() {
        guard let objectIDs = try? AudioObjectID.readProcessList() else {
            Self.logger.error("Failed to read HAL process list")
            return
        }

        struct Group {
            let app: NSRunningApplication
            var objects: [AudioObjectID] = []
            var playing = false
            var recording = false
        }
        var groups: [pid_t: Group] = [:]
        // HAL objects whose audio plays but which no application claims —
        // if an app's sound flows through one of these, no slider can ever
        // reach it. Collected for the X-ray diag line below.
        var orphans: [String] = []

        for objectID in objectIDs {
            guard let pid = try? objectID.readProcessPID() else { continue }

            // Helper processes answer to the app the user knows; a browser tab's
            // audio belongs to the browser. Helpers that launchd spawned with
            // no responsibility link (Talk's audio helper, resp == self) are
            // matched by their executable path living inside an app bundle.
            let ownerPID = Self.responsiblePID(for: pid)
            guard let running = NSRunningApplication(processIdentifier: ownerPID)
                ?? NSRunningApplication(processIdentifier: pid)
                ?? Self.runningAppContainingProcess(pid),
                let bundleID = running.bundleIdentifier,
                bundleID != Bundle.main.bundleIdentifier
            else {
                if objectID.readProcessIsRunningOutput() {
                    orphans.append("obj=\(objectID) pid=\(pid) resp=\(ownerPID) \(Self.processName(pid))")
                }
                continue
            }

            let key = running.processIdentifier
            var group = groups[key] ?? Group(app: running)
            group.objects.append(objectID)
            group.playing = group.playing || objectID.readProcessIsRunningOutput()
            group.recording = group.recording || objectID.readProcessIsRunningInput()
            groups[key] = group
        }

        if orphans != lastPlayingOrphans {
            lastPlayingOrphans = orphans
            if !orphans.isEmpty {
                Diag.log("hal playing orphans (audio no app claims): \(orphans.joined(separator: " | "))")
            }
        }

        // Every regular GUI app stays listed even before it makes sound, so
        // its slider can be set ahead of time. Apps already grouped above
        // (they own HAL processes) keep their richer state.
        for running in NSWorkspace.shared.runningApplications {
            guard running.activationPolicy == .regular,
                  let bundleID = running.bundleIdentifier,
                  bundleID != Bundle.main.bundleIdentifier,
                  groups[running.processIdentifier] == nil
            else { continue }
            groups[running.processIdentifier] = Group(app: running)
        }

        var nextApps = groups.compactMap { pid, group -> AudioApp? in
            // Regular apps always; agents and helpers only while they actually
            // play or record — keeps Control Center, Siri, and GPU helpers out
            // without dropping background recorders (meeting helpers).
            guard group.app.activationPolicy == .regular || group.playing || group.recording
            else { return nil }
            return AudioApp(
                id: pid,
                bundleID: group.app.bundleIdentifier ?? "",
                name: group.app.localizedName ?? group.app.bundleIdentifier ?? "pid \(pid)",
                objectIDs: group.objects.sorted(),
                isPlaying: group.playing,
                isRecording: group.recording
            )
        }
        nextApps = AudioApp.coalescedByBundleID(nextApps)

        // Playing apps first, then apps known to Core Audio (audio-capable),
        // then the rest — alphabetical within each tier; stable for equal keys.
        nextApps.sort {
            if $0.isPlaying != $1.isPlaying { return $0.isPlaying }
            if $0.objectIDs.isEmpty != $1.objectIDs.isEmpty { return !$0.objectIDs.isEmpty }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

        if nextApps != apps {
            apps = nextApps
            let names = nextApps.map { "\($0.name)\($0.isPlaying ? "*" : "")" }.joined(separator: ", ")
            // App names stay redacted in the unified log (default .private).
            Self.logger.info("Apps: \(nextApps.count)/\(objectIDs.count) HAL processes — \(names)")
            Diag.log("apps \(nextApps.count)/\(objectIDs.count): \(names)")
        }
    }

    // MARK: - Responsible process lookup

    private typealias ResponsiblePIDFunction = @convention(c) (pid_t) -> pid_t

    /// `responsibility_get_pid_responsible_for_pid` maps helper processes to
    /// the app that spawned them — the same attribution TCC uses. Private SPI:
    /// not in any public header, but stable since macOS 10.14 and widely used
    /// in open-source tools. If it ever disappears, the `?? pid` fallback
    /// degrades gracefully to per-helper attribution (browser audio shows as
    /// its helper process instead of the browser).
    private static let responsiblePIDFunction: ResponsiblePIDFunction? = {
        guard let handle = dlopen(nil, RTLD_NOW),
              let symbol = dlsym(handle, "responsibility_get_pid_responsible_for_pid")
        else { return nil }
        return unsafeBitCast(symbol, to: ResponsiblePIDFunction.self)
    }()

    /// Executable name of a pid for the orphan X-ray line (best effort).
    private static func processName(_ pid: pid_t) -> String {
        var path = [CChar](repeating: 0, count: 1024)
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return "(unknown)" }
        return String(cString: path).split(separator: "/").last.map(String.init) ?? "(unknown)"
    }

    /// An Electron/Chromium audio helper can run as a launchd agent with no
    /// responsibility link to its parent app — Kontur Talk's helper answers
    /// "myself" to the responsibility query, so the usual attribution skips
    /// it and its audio plays past every slider. But the executable still
    /// lives inside the owning app's bundle, so match the process path's
    /// root .app component against running applications' bundle URLs.
    private static func runningAppContainingProcess(_ pid: pid_t) -> NSRunningApplication? {
        var buffer = [CChar](repeating: 0, count: 1024)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let components = URL(fileURLWithPath: String(cString: buffer)).pathComponents
        guard let appIndex = components.firstIndex(where: { $0.hasSuffix(".app") }),
              appIndex > 1 else { return nil }
        let bundleURL = URL(fileURLWithPath: components[...appIndex].joined(separator: "/"))
        return NSWorkspace.shared.runningApplications.first {
            $0.bundleURL == bundleURL && $0.bundleIdentifier != nil
        }
    }

    private static func responsiblePID(for pid: pid_t) -> pid_t {
        guard let function = responsiblePIDFunction else { return pid }
        let owner = function(pid)
        return owner > 0 ? owner : pid
    }
}
