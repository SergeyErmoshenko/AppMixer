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
    let isPlaying: Bool
    let isRecording: Bool

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
                isPlaying: existing.isPlaying || app.isPlaying,
                isRecording: existing.isRecording || app.isRecording
            )
        }
        return result
    }
}
