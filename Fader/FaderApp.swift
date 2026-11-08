import AppKit
import CoreAudio
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak static var engine: MixerEngine?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // As an LSUIElement agent with no open window, RunningBoard rates the
        // app's termination resistance at its lowest, so under disk pressure
        // the cache-delete daemon evicts it (exit reason 0xBADDD15C) and the
        // icon silently vanishes — it won't relaunch until next login. Raising
        // resistance tells the system not to reclaim us first; it's a strong
        // hint, not a guarantee under severe pressure.
        ProcessInfo.processInfo.disableSuddenTermination()
        ProcessInfo.processInfo.disableAutomaticTermination("Menu bar agent stays resident")
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Process taps are private to this process and must always be faded
        // and released — releasing restores every app's native audio path.
        Self.engine?.fadeOutAndStop()
    }
}

@main
struct FaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var engine: MixerEngine
    @State private var statusMenu: StatusItemMenuController

    init() {
        Self.yieldToRunningInstance()
        let engine = MixerEngine()
        let statusMenu = StatusItemMenuController()
        _engine = State(initialValue: engine)
        _statusMenu = State(initialValue: statusMenu)
        AppDelegate.engine = engine
        statusMenu.install()
        // The detached probe gates engine.start(): the first HAL contact
        // happens off the main thread, so a wedged coreaudiod hangs the probe
        // while the menu bar icon renders and shows a waiting state. start()
        // only runs once the HAL has proven responsive.
        Task.detached(priority: .userInitiated) {
            _ = try? AudioObjectID.readDefaultOutputDevice()
            await MainActor.run {
                engine.start()
            }
        }
    }

    /// A second copy (dev build, stray drag to another folder) must not run
    /// alongside the first: two engines would fight over process taps.
    /// Launch Services already refuses to double-launch the same bundle, so
    /// reaching this means a copy at a different path — name the live one and
    /// bow out.
    private static func yieldToRunningInstance() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let myPID = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != myPID }
        guard let other = others.first else { return }
        let alert = NSAlert()
        alert.messageText = "AppMixer is already running"
        alert.informativeText = "Another copy is running from \(other.bundleURL?.path ?? "another location")."
        NSApp.activate()
        alert.runModal()
        exit(0)
    }

    /// SwiftUI's name-based Image fails to resolve loose bundle resources in
    /// a MenuBarExtra label; load via AppKit. isTemplate makes the system
    /// tint the mark to match the menu bar theme.
    private static let menuBarIcon: NSImage = {
        let image = NSImage(named: "MenuBarIconTemplate") ?? NSImage()
        image.isTemplate = true
        return image
    }()

    var body: some Scene {
        MenuBarExtra {
            MixerView()
                .environment(engine)
        } label: {
            Image(nsImage: Self.menuBarIcon)
        }
        .menuBarExtraStyle(.window)
    }
}
