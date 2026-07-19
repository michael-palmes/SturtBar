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
    private let updateStore: UpdateStore?
    private(set) var settingsWindow: NSWindow?
    private(set) var aboutWindow: NSWindow?

    init(settings: SettingsStore, updateStore: UpdateStore? = nil) {
        self.settings = settings
        self.updateStore = updateStore
    }

    func showSettings() {
        let window = self.settingsWindow ?? self.makeSettingsWindow()
        self.settingsWindow = window
        // Recreate the rootView on every show so that @State (e.g. launchAtLogin) is fresh.
        // The reused window never triggers .onAppear again after the first show, so stale
        // checkbox state would persist for the lifetime of the process without this.
        if let hosting = window.contentViewController as? NSHostingController<SettingsView> {
            hosting.rootView = self.makeSettingsRoot()
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
        let hosting = NSHostingController(rootView: self.makeSettingsRoot())
        hosting.sizingOptions = .preferredContentSize
        return self.makeWindow(contentViewController: hosting, title: "SturtBar Settings")
    }

    private func makeSettingsRoot() -> SettingsView {
        var view = SettingsView(settings: self.settings, updateStore: self.updateStore)
        // AppKit reads preferredContentSize only at creation; content changes resize via this hook.
        view.onNaturalSize = { [weak self] size in
            self?.resizeSettingsWindow(to: size)
        }
        return view
    }

    /// Top-left-anchored resize to a content size; internal so headless tests can drive it.
    func resizeSettingsWindow(to size: CGSize) {
        guard let window = self.settingsWindow, size.width > 1, size.height > 1 else { return }
        let current = window.contentRect(forFrameRect: window.frame).size
        guard abs(current.width - size.width) > 0.5 || abs(current.height - size.height) > 0.5
        else { return }
        var frame = window.frameRect(forContentRect: CGRect(origin: .zero, size: size))
        frame.origin.x = window.frame.origin.x
        frame.origin.y = window.frame.maxY - frame.height
        window.setFrame(frame, display: true, animate: window.isVisible)
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
