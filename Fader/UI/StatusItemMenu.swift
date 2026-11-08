import AppKit
import ServiceManagement

/// Right-click menu for the menu bar icon. MenuBarExtra(.window) offers no
/// native context menu, so a local event monitor intercepts right-clicks
/// (and control-clicks) landing on the status bar window; left clicks pass
/// through and keep toggling the popover.
@MainActor
final class StatusItemMenuController: NSObject {
    private var monitor: Any?

    func install() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
            guard event.window?.className == "NSStatusBarWindow",
                  event.type == .rightMouseDown || event.modifierFlags.contains(.control)
            else { return event }
            // Local monitors fire on the main thread; hop into the actor
            // without returning the non-Sendable event through it.
            MainActor.assumeIsolated {
                self?.showMenu(with: event)
            }
            return nil
        }
    }

    private func showMenu(with event: NSEvent) {
        guard let view = event.window?.contentView else { return }

        let menu = NSMenu()
        menu.autoenablesItems = false
        // The status bar window is pinned dark; without this the menu
        // inherits that and ignores the system theme.
        menu.appearance = NSApp.effectiveAppearance

        let header = NSMenuItem(title: "AppMixer \(Bundle.main.shortVersion)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())

        let credits = NSMenuItem(title: "Original project: fader", action: #selector(visitOriginal), keyEquivalent: "")
        credits.target = self
        menu.addItem(credits)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit AppMixer", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            // The next menu open re-reads the real status; nothing to undo.
        }
    }

    @objc private func visitOriginal() {
        if let url = URL(string: "https://github.com/pantafive/fader") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

extension Bundle {
    var shortVersion: String {
        infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }
}
