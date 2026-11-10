import AppKit
import CoreAudio

/// A running application that owns one or more HAL audio processes.
/// Browsers and Electron apps play audio from helper processes; they group
/// under the responsible application here.
struct AudioApp: Identifiable, Hashable {
    let id: pid_t
    let bundleID: String
    let name: String
    let objectIDs: [AudioObjectID]
    /// The subset a process tap may intercept: objects attributed through
    /// responsibility / NSRunningApplication. Objects rescued from orphanhood
    /// (bundle-path or name-prefix tiers — vendor system audio agents) are
    /// listed for visibility but NEVER tapped: on them the tap's muting works
    /// while its capture returns nothing (Talk's helper: input=never across
    /// the whole call in telemetry), so tapping them silences the app with
    /// nothing re-rendered — and wedges the helper.
    let tapObjectIDs: [AudioObjectID]
    let isPlaying: Bool
    let isRecording: Bool

    init(id: pid_t, bundleID: String, name: String, objectIDs: [AudioObjectID],
         tapObjectIDs: [AudioObjectID]? = nil, isPlaying: Bool, isRecording: Bool) {
        self.id = id
        self.bundleID = bundleID
        self.name = name
        self.objectIDs = objectIDs
        // nil = "every object is tap-eligible"; an explicit empty array means
        // "none are" (all objects are orphan-rescued agents).
        self.tapObjectIDs = tapObjectIDs ?? objectIDs
        self.isPlaying = isPlaying
        self.isRecording = isRecording
    }

    /// App icon resolved through NSRunningApplication; cheap, AppKit caches it.
    @MainActor
    var icon: NSImage {
        NSRunningApplication(processIdentifier: id)?.icon
            ?? NSWorkspace.shared.icon(for: .applicationBundle)
    }
}

extension AudioApp {
    /// Multiple independently launched copies of one application can own
    /// different HAL process objects while sharing a bundle identifier. Fader
    /// exposes one slider per bundle, so fold those copies together instead of
    /// letting a duplicate dictionary key trap the main actor.
    static func coalescedByBundleID(_ apps: [AudioApp]) -> [AudioApp] {
        var indices: [String: Int] = [:]
        var result: [AudioApp] = []

        for app in apps {
            guard let index = indices[app.bundleID] else {
                indices[app.bundleID] = result.count
                result.append(app)
                continue
            }

            let existing = result[index]
            let representative = existing.id <= app.id ? existing : app
            result[index] = AudioApp(
                id: representative.id,
                bundleID: app.bundleID,
                name: representative.name,
                objectIDs: Array(Set(existing.objectIDs + app.objectIDs)).sorted(),
                tapObjectIDs: Array(Set(existing.tapObjectIDs + app.tapObjectIDs)).sorted(),
                isPlaying: existing.isPlaying || app.isPlaying,
                isRecording: existing.isRecording || app.isRecording
            )
        }
        return result
    }
}
