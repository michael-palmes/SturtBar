// WindowsController.swift — lazily-created, reusable Settings and About windows (Phase 4b).
//
// The rebuild deliberately avoids the SwiftUI `Settings` scene and the legacy
// `showPreferencesWindow:` selector dance: each window is a plain NSWindow wrapping an
// NSHostingController, created on first show, kept alive (`isReleasedWhenClosed = false`) and
// re-fronted on subsequent shows — closing only hides, so repeated open/close never accumulates
// windows. The app is an accessory (no Dock icon), so showing a window must also activate the
// app or it would order in behind the frontmost app without key status.

import AppKit
import SwiftUI

// MARK: - WindowsController

@MainActor
final class WindowsController {
    private let settings: SettingsStore
    private(set) var settingsWindow: NSWindow?
    private(set) var aboutWindow: NSWindow?

    init(settings: SettingsStore) {
        self.settings = settings
    }

    func showSettings() {
        let window = self.settingsWindow ?? self.makeSettingsWindow()
        self.settingsWindow = window
        // Recreate the rootView on every show so that @State (e.g. launchAtLogin) is fresh.
        // The reused window never triggers .onAppear again after the first show, so stale
        // checkbox state would persist for the lifetime of the process without this.
        if let hosting = window.contentViewController as? NSHostingController<SettingsView> {
            hosting.rootView = SettingsView(settings: self.settings, onShowAbout: { [weak self] in self?.showAbout() })
        }
        self.present(window)
    }

    func showAbout() {
        let window = self.aboutWindow ?? self.makeAboutWindow()
        self.aboutWindow = window
        self.present(window)
    }

    private func present(_ window: NSWindow) {
        // Tests construct windows headlessly; never order them onto the developer's screen.
        guard !ProcessEnvironment.isRunningTests else { return }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeSettingsWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: SettingsView(
            settings: self.settings,
            onShowAbout: { [weak self] in self?.showAbout() }))
        hosting.sizingOptions = .preferredContentSize
        return self.makeWindow(contentViewController: hosting, title: "SturtBar Settings")
    }

    private func makeAboutWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: AboutView())
        hosting.sizingOptions = .preferredContentSize
        return self.makeWindow(contentViewController: hosting, title: "About SturtBar")
    }

    private func makeWindow(contentViewController: NSViewController, title: String) -> NSWindow {
        let window = NSWindow(contentViewController: contentViewController)
        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable]
        // Reuse contract: closing hides the window; the controller keeps the only reference.
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }
}
